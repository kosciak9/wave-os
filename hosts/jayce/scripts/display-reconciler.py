#!/usr/bin/env python3
"""Session-local, event driven Hyprland display reconciliation."""

import argparse
import codecs
import json
import os
import re
import selectors
import socket
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path


INTERNAL = "eDP-1"
EVENT_DELAY = 0.20
GENERATED_EVENT_TIMEOUT = 5.0


def identity(description):
    """Return a stable description identity, deliberately excluding commas."""
    value = re.sub(r"\s+", " ", (description or "").replace(",", " ")).strip()
    return "description:" + value if value else ""


def connector_identity(connector):
    return "connector:" + connector if connector else ""


def positive(value):
    try:
        return int(value) > 0
    except (TypeError, ValueError):
        return False


def managed_workspace(workspace):
    """Whether Hyprland's workspace is one we must migrate and own."""
    if not isinstance(workspace, dict) or not positive(workspace.get("id")):
        return False
    try:
        has_windows = int(workspace.get("windows", 0)) > 0
    except (TypeError, ValueError):
        has_windows = False
    return bool(workspace.get("ispersistent")) or has_windows


def next_suspend_retry_delay(delay):
    return min(max(delay * 2.0, 1.0), 30.0)


@dataclass
class PendingMove:
    old_connector: str
    destination: str
    when: float
    generated: bool = False


class Ownership:
    """Pure state machine for workspace moves and monitor lifecycle events."""

    def __init__(self, data=None):
        self.data = data or {"workspaces": {}, "last_active": {}, "outputs": {}}
        self.data.setdefault("workspaces", {})
        self.data.setdefault("last_active", {})
        self.data.setdefault("outputs", {})
        self.pending = {}
        self.removed_connectors = set()
        self.pre_restore_connectors = {}
        # These are live maps only.  Persisted entries are known history and
        # must not make a disconnected connector look currently connected.
        self.connector_to_identity = {}
        self.identity_to_connector = {}

    def mappings(self, monitors):
        known = dict(self.data["outputs"].get("connector_to_identity", {}))
        descriptions = {}
        for monitor in monitors:
            desc = identity(monitor.get("description"))
            if desc:
                descriptions.setdefault(desc, []).append(monitor["name"])
        self.connector_to_identity = {}
        self.identity_to_connector = {}
        for monitor in monitors:
            connector = monitor.get("name", "")
            desc = identity(monitor.get("description"))
            stable = desc if desc and len(descriptions[desc]) == 1 else connector_identity(connector)
            self.connector_to_identity[connector] = stable
            self.identity_to_connector.setdefault(stable, connector)
            if stable.startswith("description:"):
                self.identity_to_connector[stable] = connector
            known[connector] = stable
        # Keep disconnected outputs in the session record, but never expose
        # them through the live maps used to choose restoration destinations.
        self.data["outputs"]["connector_to_identity"] = known

    def workspace(self, workspace_id, current=None, desired=None):
        if not positive(workspace_id):
            return
        item = self.data["workspaces"].setdefault(str(workspace_id), {})
        if current is not None:
            item["current_connector"] = current
        if desired is not None:
            item["desired_identity"] = desired

    def move_event(self, workspace_id, destination, generated=False):
        if not positive(workspace_id):
            return
        key = str(workspace_id)
        old = self.data["workspaces"].get(key, {}).get("current_connector", "")
        self.workspace(key, current=destination)
        generated = generated or (
            destination in self.pre_restore_connectors
            and time.monotonic() - self.pre_restore_connectors[destination] < 2.0
        )
        self.pending[key] = PendingMove(old, destination, time.monotonic(), generated)

    def monitor_removed(self, connector):
        self.removed_connectors.add(connector)
        for pending in self.pending.values():
            if pending.old_connector == connector:
                # Hyprland evacuates workspaces before emitting removal.  Keep
                # this classification on the pending record: a quick re-add
                # must not turn the evacuation into a user move.
                pending.generated = True
        for item in self.data["workspaces"].values():
            if item.get("current_connector") == connector:
                item["current_connector"] = ""

    def monitor_added(self, connector, resolved_identity=None):
        self.removed_connectors.discard(connector)
        self.pre_restore_connectors[connector] = time.monotonic()
        if resolved_identity:
            for key, pending in self.pending.items():
                desired = self.data["workspaces"].get(key, {}).get("desired_identity")
                if pending.destination == connector and desired == resolved_identity:
                    pending.generated = True

    def flush(self, now=None):
        now = time.monotonic() if now is None else now
        for key, pending in list(self.pending.items()):
            if now - pending.when < EVENT_DELAY:
                continue
            automatic = pending.old_connector in self.removed_connectors
            if not automatic and not pending.generated:
                destination = self.connector_to_identity.get(
                    pending.destination, connector_identity(pending.destination)
                )
                self.workspace(key, desired=destination)
            self.pending.pop(key, None)


def load_state(path):
    try:
        with open(path, encoding="utf-8") as stream:
            return Ownership(json.load(stream))
    except (OSError, ValueError):
        return Ownership()


def save_state(path, ownership):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(ownership.data, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


@dataclass
class CommandResult:
    status: int
    stdout: str
    stderr: str

    @property
    def ok(self):
        return self.status == 0


def run(*args, timeout=8):
    try:
        result = subprocess.run(
            args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, check=False,
        )
        if result.returncode:
            print(
                "wave-display-reconciler: command failed (%d): %s: %s"
                % (result.returncode, " ".join(args), result.stderr.strip()),
                file=sys.stderr,
            )
        return CommandResult(result.returncode, result.stdout, result.stderr)
    except (OSError, subprocess.SubprocessError) as error:
        print("wave-display-reconciler: command failed: %s: %s" % (" ".join(args), error), file=sys.stderr)
        return CommandResult(127, "", str(error))


def json_query(*args):
    """Return parsed JSON, or None when the command/query was not reliable."""
    result = run(*args)
    if not result.ok:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        print("wave-display-reconciler: invalid JSON from %s" % " ".join(args), file=sys.stderr)
        return None


def lid_state():
    for path in Path("/proc/acpi/button/lid").glob("*/state"):
        try:
            value = path.read_text(encoding="utf-8").split(":", 1)[1].strip().lower()
            return "closed" if value.startswith("closed") else "open"
        except (OSError, IndexError):
            continue
    return "unknown"


def lid_policy(monitors):
    """Classify topology before doing any action; in particular never target None."""
    external = [monitor for monitor in monitors if monitor.get("name") != INTERNAL]
    internal = any(monitor.get("name") == INTERNAL for monitor in monitors)
    if not external:
        return "suspend", None
    if not internal:
        return "steady", None
    return "migrate", external


def last_active_candidate(ownership, target_connector):
    """Return only an active workspace already verified on target_connector."""
    target_identity = ownership.connector_to_identity.get(
        target_connector, connector_identity(target_connector)
    )
    workspace_id = ownership.data.get("last_active", {}).get(target_identity)
    item = ownership.data.get("workspaces", {}).get(str(workspace_id), {})
    if positive(workspace_id) and item.get("current_connector") == target_connector:
        return str(workspace_id)
    return None


class EventBuffer:
    """Socket2 line framing; recv chunks may contain fragments or many events."""

    def __init__(self):
        self.buffer = ""

    def feed(self, chunk):
        self.buffer += chunk
        lines = self.buffer.split("\n")
        self.buffer = lines.pop()
        return [line for line in lines if line]

    def reset(self):
        self.buffer = ""


def new_event_decoder():
    return codecs.getincrementaldecoder("utf-8")()


def decode_event_bytes(decoder, raw):
    """Distinguish EOF from a valid recv carrying only a partial codepoint."""
    if raw == b"":
        return True, ""
    return False, decoder.decode(raw, final=False)


class Reconciler:
    def __init__(self, state_path=None):
        runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%s" % os.getuid())
        self.state_path = Path(state_path or Path(runtime) / "wave-display-reconciler.json")
        self.ownership = load_state(self.state_path)
        self.lock = threading.RLock()
        self.generated = {}
        self.last_external = ""
        self.preferred_external_identity = self.ownership.data.get(
            "preferred_external_identity", ""
        )
        self.lid_action = "unknown"
        self.suspend_requested = False
        self.suspend_retry_at = 0.0
        self.suspend_delay = 1.0
        self.closed_migrated = False
        self.pending_active_restore = {}

    def blackout(self):
        run("qs", "-c", "wave", "ipc", "call", "blackout", "trigger")
        time.sleep(0.08)

    def snapshot(self):
        monitors = json_query("hyprctl", "monitors", "-j")
        if not isinstance(monitors, list) or any(not isinstance(m, dict) for m in monitors):
            return None
        workspace_list = json_query("hyprctl", "workspaces", "-j")
        if (not isinstance(workspace_list, list)
                or any(not isinstance(w, dict) for w in workspace_list)):
            return None
        self.ownership.mappings(monitors)
        managed_ids = {
            str(workspace.get("id"))
            for workspace in workspace_list
            if managed_workspace(workspace)
        }
        for workspace_id in list(self.ownership.data["workspaces"]):
            if positive(workspace_id) and workspace_id not in managed_ids:
                self.destroy_workspace(workspace_id)
        for workspace in workspace_list:
            workspace_id = workspace.get("id")
            if not managed_workspace(workspace):
                continue
            connector = workspace.get("monitor", "")
            stable = self.ownership.connector_to_identity.get(connector, connector_identity(connector))
            item = self.ownership.data["workspaces"].setdefault(str(workspace_id), {})
            item["current_connector"] = connector
            item.setdefault("desired_identity", stable)
        for monitor in monitors:
            active = monitor.get("activeWorkspace", {})
            workspace_id = active.get("id")
            connector = monitor.get("name", "")
            stable = self.ownership.connector_to_identity.get(connector, connector_identity(connector))
            if positive(workspace_id) and stable and stable not in self.pending_active_restore:
                self.ownership.data["last_active"][stable] = workspace_id
            if monitor.get("focused") and connector != INTERNAL:
                self.last_external = connector
                self.preferred_external_identity = stable
                self.ownership.data["preferred_external_identity"] = stable
        save_state(self.state_path, self.ownership)
        return monitors

    def destroy_workspace(self, workspace_id):
        key = str(workspace_id)
        if not positive(key):
            return
        self.ownership.data["workspaces"].pop(key, None)
        self.ownership.data["last_active"] = {
            stable: active_id
            for stable, active_id in self.ownership.data["last_active"].items()
            if str(active_id) != key
        }
        self.ownership.pending.pop(key, None)
        self.generated.pop(key, None)

    def move(self, workspace_id, target):
        key = str(workspace_id)
        if self.ownership.data["workspaces"].get(key, {}).get("current_connector") == target:
            return True
        self.generated[key] = (target, time.monotonic())
        command = 'hl.dsp.workspace.move({ workspace = "%s", monitor = "%s" })' % (key, target)
        result = run("hyprctl", "dispatch", command)
        if not result.ok:
            self.generated.pop(key, None)
            return False
        for _ in range(15):
            current = json_query("hyprctl", "workspaces", "-j")
            if isinstance(current, list) and any(
                str(w.get("id")) == key and w.get("monitor") == target for w in current
            ):
                self.ownership.workspace(key, current=target)
                save_state(self.state_path, self.ownership)
                return True
            time.sleep(0.08)
        print("wave-display-reconciler: workspace %s did not reach %s" % (key, target), file=sys.stderr)
        self.generated.pop(key, None)
        return False

    def consume_generated(self, workspace_id, destination):
        key = str(workspace_id)
        generated = self.generated.get(key)
        if generated and generated[0] == destination:
            self.generated.pop(key, None)
            return True
        return False

    def target_external(self, monitors):
        external = [m for m in monitors if m.get("name") != INTERNAL]
        if not external:
            return None
        for monitor in external:
            stable = self.ownership.connector_to_identity.get(
                monitor.get("name"), connector_identity(monitor.get("name"))
            )
            if stable == self.preferred_external_identity:
                return monitor["name"]
            if monitor.get("name") == self.last_external:
                return monitor["name"]
        focused = next((m for m in external if m.get("focused")), None)
        return (focused or sorted(external, key=lambda m: m.get("name", ""))[0])["name"]

    def restore_outputs(self, monitors):
        previous_focus = next(
            (monitor.get("name") for monitor in monitors if monitor.get("focused")),
            None,
        )
        self.ownership.mappings(monitors)
        connected = set(self.ownership.connector_to_identity)
        for workspace_id, item in list(self.ownership.data["workspaces"].items()):
            desired = item.get("desired_identity")
            target = self.ownership.identity_to_connector.get(desired)
            if positive(workspace_id) and desired and target in connected and item.get("current_connector") != target:
                self.move(workspace_id, target)
        restored_focus = set()
        for target in connected:
            if target in restored_focus:
                continue
            workspace_id = last_active_candidate(self.ownership, target)
            if not workspace_id:
                continue
            restored_focus.add(target)
            try:
                run("hyprctl", "dispatch", 'hl.dsp.focus({ monitor = "%s" })' % target)
                if last_active_candidate(self.ownership, target) == workspace_id:
                    run(
                        "hyprctl", "dispatch",
                        'hl.dsp.focus({ workspace = "%s", on_current_monitor = true })'
                        % workspace_id,
                    )
            finally:
                if previous_focus in connected:
                    run("hyprctl", "dispatch", 'hl.dsp.focus({ monitor = "%s" })' % previous_focus)
        save_state(self.state_path, self.ownership)

    def begin_monitor_reconnect(self, connector, stable_identity):
        """Protect the pre-disconnect active workspace during Hyprland settle."""
        self.begin_topology_transition()

    def finish_monitor_reconnect(self, stable_identity):
        self.pending_active_restore.clear()

    def begin_topology_transition(self):
        """Freeze every known output's active workspace until restoration ends."""
        self.pending_active_restore = {
            stable: workspace_id
            for stable, workspace_id in self.ownership.data.get("last_active", {}).items()
            if positive(workspace_id)
        }

    def finish_topology_transition(self):
        self.pending_active_restore.clear()

    def close(self):
        with self.lock:
            monitors = self.snapshot()
            if monitors is None:
                return
            policy, _ = lid_policy(monitors)
            if policy == "suspend":
                if not self.suspend_requested and time.monotonic() >= self.suspend_retry_at:
                    self.blackout()
                    run("systemctl", "--user", "stop", "wave-backlight-dim.service")
                    run("loginctl", "lock-session")
                    result = run("systemctl", "suspend")
                    if result.ok:
                        print("wave-display-reconciler: suspend requested", file=sys.stderr)
                        self.suspend_requested = True
                        self.suspend_retry_at = 0.0
                        self.suspend_delay = 1.0
                    else:
                        print("wave-display-reconciler: suspend denied; daemon remains active", file=sys.stderr)
                        self.suspend_retry_at = time.monotonic() + self.suspend_delay
                        self.suspend_delay = next_suspend_retry_delay(self.suspend_delay)
                return
            target = self.target_external(monitors)
            if policy == "steady":
                self.restore_outputs(monitors)
                self.lid_action = "closed"
                self.suspend_retry_at = 0.0
                self.suspend_delay = 1.0
                return
            if not target:
                print("wave-display-reconciler: migration topology had no target", file=sys.stderr)
                return
            if self.lid_action == "closed" and self.closed_migrated:
                return
            self.blackout()
            run("systemctl", "--user", "stop", "wave-backlight-dim.service")
            workspace_list = json_query("hyprctl", "workspaces", "-j")
            if not isinstance(workspace_list, list):
                return
            internal_workspaces = [
                w["id"] for w in workspace_list
                if w.get("monitor") == INTERNAL and managed_workspace(w)
            ]
            for workspace_id in internal_workspaces:
                self.move(workspace_id, target)
            remaining = json_query("hyprctl", "workspaces", "-j")
            if not isinstance(remaining, list):
                return
            if not any(
                w.get("monitor") == INTERNAL and managed_workspace(w)
                for w in remaining
            ):
                result = run("hyprctl", "eval", 'hl.monitor({ output = "eDP-1", disabled = true })')
                if result.ok:
                    self.closed_migrated = True
                    self.suspend_retry_at = 0.0
                    self.suspend_delay = 1.0
            self.lid_action = "closed"
            save_state(self.state_path, self.ownership)

    def open(self):
        with self.lock:
            if self.lid_action == "open":
                return
            self.begin_topology_transition()
            self.blackout()
            try:
                run("hyprctl", "reload")
                for _ in range(40):
                    monitors = self.snapshot()
                    if monitors is None:
                        time.sleep(0.1)
                        continue
                    if any(m.get("name") == INTERNAL for m in monitors):
                        self.restore_outputs(monitors)
                        self.lid_action = "open"
                        self.suspend_requested = False
                        self.suspend_retry_at = 0.0
                        self.suspend_delay = 1.0
                        self.closed_migrated = False
                        return
                    time.sleep(0.1)
                print("wave-display-reconciler: eDP-1 did not return after reload", file=sys.stderr)
            finally:
                self.finish_topology_transition()

    def reconcile(self):
        with self.lock:
            monitors = self.snapshot()
            if monitors is None:
                return
            if lid_state() == "closed":
                return self.close()
            if not any(monitor.get("name") == INTERNAL for monitor in monitors):
                self.lid_action = "unknown"
                return self.open()
            self.restore_outputs(monitors)
            self.lid_action = "open"
            self.suspend_requested = False
            self.suspend_retry_at = 0.0
            self.suspend_delay = 1.0

    def socket_connected(self):
        """Reconcile each initial connection and every socket reconnect."""
        self.reconcile()

    def retry_suspend_if_due(self):
        """Retry denied suspend without blocking the selector loop."""
        if not self.suspend_retry_at or self.suspend_requested:
            return
        monitors = json_query("hyprctl", "monitors", "-j")
        if not isinstance(monitors, list):
            return
        if lid_state() != "closed" or any(m.get("name") != INTERNAL for m in monitors):
            self.suspend_retry_at = 0.0
            self.suspend_delay = 1.0
            return
        if time.monotonic() >= self.suspend_retry_at:
            self.close()


def parse_event(line):
    event, separator, payload = line.partition(">>")
    if not separator:
        return "", []
    if event == "moveworkspacev2":
        parts = payload.split(",", 2)
    elif event in ("monitorremovedv2", "monitoraddedv2"):
        parts = payload.split(",", 2)
    else:
        parts = payload.split(",")
    return event, parts


def event_refreshes_snapshot(event):
    return event in ("workspacev2", "focusedmonv2", "createworkspacev2")


def notify(action):
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%s" % os.getuid())
    path = os.environ.get("WAVE_DISPLAY_SOCKET", runtime + "/wave-display-reconciler.sock")
    try:
        control = socket.socket(socket.AF_UNIX)
        control.settimeout(0.05)
        control.connect(path)
        control.sendall((action + "\n").encode())
        control.close()
    except OSError:
        pass


def daemon():
    reconciler = Reconciler()
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%s" % os.getuid()))
    control_path = runtime / "wave-display-reconciler.sock"
    try:
        control_path.unlink()
    except FileNotFoundError:
        pass
    control = socket.socket(socket.AF_UNIX)
    control.bind(str(control_path))
    os.chmod(control_path, 0o600)
    control.listen(8)
    control.setblocking(False)
    selector = selectors.DefaultSelector()
    selector.register(control, selectors.EVENT_READ, "control")
    hypr = None
    event_path = runtime / "hypr" / os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "") / ".socket2.sock"
    event_buffer = EventBuffer()
    decoder = new_event_decoder()
    deferred_snapshot_at = None
    try:
        while True:
            if hypr is None:
                try:
                    hypr = socket.socket(socket.AF_UNIX)
                    hypr.settimeout(1)
                    hypr.connect(str(event_path))
                    hypr.setblocking(False)
                    selector.register(hypr, selectors.EVENT_READ, "hypr")
                    decoder = new_event_decoder()
                    event_buffer.reset()
                    deferred_snapshot_at = None
                    reconciler.socket_connected()
                except OSError:
                    if hypr is not None:
                        hypr.close()
                    hypr = None
                    event_buffer.reset()
                    decoder = new_event_decoder()
                    deferred_snapshot_at = None
            for key, _ in selector.select(0.25):
                if key.data == "control":
                    client, _ = control.accept()
                    action = client.recv(64).decode().strip()
                    client.close()
                    if action == "lid-close":
                        reconciler.close()
                    elif action == "lid-open":
                        reconciler.open()
                    continue
                elif hypr is not None:
                    connection = hypr
                    try:
                        eof, chunk = decode_event_bytes(decoder, connection.recv(4096))
                        if eof:
                            raise OSError("socket closed")
                        for line in event_buffer.feed(chunk) if chunk else []:
                            event, parts = parse_event(line)
                            if event == "moveworkspacev2" and len(parts) == 3:
                                workspace_id, _, destination = parts
                                generated = reconciler.consume_generated(workspace_id, destination)
                                reconciler.ownership.move_event(workspace_id, destination, generated)
                            elif event == "destroyworkspacev2" and parts:
                                reconciler.destroy_workspace(parts[0])
                                save_state(reconciler.state_path, reconciler.ownership)
                            elif event == "monitorremovedv2" and len(parts) >= 2:
                                deferred_snapshot_at = None
                                reconciler.ownership.monitor_removed(parts[1])
                                reconciler.begin_topology_transition()
                                try:
                                    if lid_state() == "closed":
                                        reconciler.close()
                                    else:
                                        reconciler.reconcile()
                                finally:
                                    reconciler.finish_topology_transition()
                            elif event == "monitoraddedv2" and len(parts) >= 2:
                                deferred_snapshot_at = None
                                resolved = identity(parts[2]) if len(parts) == 3 else None
                                reconciler.ownership.monitor_added(parts[1], resolved)
                                reconciler.begin_monitor_reconnect(parts[1], resolved)
                                time.sleep(0.25)
                                try:
                                    reconciler.reconcile()
                                finally:
                                    reconciler.finish_monitor_reconnect(resolved)
                            elif event == "focusedmonv2" and len(parts) >= 2:
                                deferred_snapshot_at = time.monotonic() + EVENT_DELAY
                            elif event_refreshes_snapshot(event):
                                deferred_snapshot_at = time.monotonic() + EVENT_DELAY
                    except (OSError, UnicodeDecodeError):
                        try:
                            selector.unregister(connection)
                        except (KeyError, ValueError):
                            pass
                        connection.close()
                        hypr = None
                        event_buffer.reset()
                        decoder = new_event_decoder()
                        deferred_snapshot_at = None
            if deferred_snapshot_at is not None and time.monotonic() >= deferred_snapshot_at:
                reconciler.snapshot()
                deferred_snapshot_at = None
            reconciler.retry_suspend_if_due()
            reconciler.ownership.flush()
            for key, (_, stamp) in list(reconciler.generated.items()):
                if time.monotonic() - stamp > GENERATED_EVENT_TIMEOUT:
                    reconciler.generated.pop(key, None)
            save_state(reconciler.state_path, reconciler.ownership)
    finally:
        selector.close()
        control.close()
        try:
            control_path.unlink()
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("daemon")
    notify_parser = subparsers.add_parser("notify")
    notify_parser.add_argument("action", choices=("lid-close", "lid-open"))
    arguments = parser.parse_args()
    if arguments.command == "daemon":
        daemon()
    else:
        notify(arguments.action)


if __name__ == "__main__":
    main()
