import copy
import hashlib
import json
import os
import pathlib
import re
import sys
import tomllib

import tomlkit

command, store_dir, claude_settings, codex_home = sys.argv[1:]
codex_home = pathlib.Path(codex_home)
handler = {"type": "command", "command": command, "timeout": 5}
# Earlier generations of this hook differ only in their store hash.
ours = re.compile(re.escape(store_dir) + r"/[a-z0-9]{32}-fugate-status-hook-[^/]+/bin/fugate-status-hook")
# Herdr's `integration install codex` always single-quotes the script path.
herdr_script = "'" + str(codex_home / "herdr-agent-state.sh").replace("'", "'\"'\"'") + "'"
herdr = re.compile(re.escape(f"bash {herdr_script}") + r" [a-z]+")

# Mirrors Codex 0.162 hook trust identities (hooks/src/engine/discovery.rs).
EVENT_LABELS = {
    "PreToolUse": "pre_tool_use",
    "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use",
    "PreCompact": "pre_compact",
    "PostCompact": "post_compact",
    "SessionStart": "session_start",
    "SessionEnd": "session_end",
    "UserPromptSubmit": "user_prompt_submit",
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
    "Stop": "stop",
    "Interrupt": "interrupt",
}
MATCHERLESS_EVENTS = {"UserPromptSubmit", "Stop", "Interrupt"}
SHORT_TIMEOUT_EVENTS = {"SessionEnd", "Interrupt"}
CONTEXT_EVENTS = {"PreToolUse", "PostToolUse", "SessionStart", "UserPromptSubmit", "SubagentStart"}
DEFAULT_CONTEXT_LIMIT = 2500


def install_stop_hook(path):
    """Keep exactly one Stop entry of the current hook; return the settings before the edit."""
    original = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    settings = copy.deepcopy(original)
    groups = settings.setdefault("hooks", {}).setdefault("Stop", [])
    for group in list(groups):
        hooks = group.get("hooks", [])
        kept = [hook for hook in hooks
                if hook.get("command") == command or not ours.fullmatch(hook.get("command", ""))]
        if len(kept) < len(hooks):
            if kept:
                group["hooks"] = kept
            else:
                groups.remove(group)
    # Codex keys hook trust by position, so a present entry stays put.
    if not any(hook.get("command") == command for group in groups for hook in group.get("hooks", [])):
        groups.append({"hooks": [dict(handler)]})
    if settings != original:
        path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    return original, settings


def managed_hooks(settings, hooks_path):
    """Yield (trust key, trust hash) of our and Herdr's command hooks."""
    for event, groups in settings.get("hooks", {}).items():
        if event not in EVENT_LABELS:
            continue
        for group_index, group in enumerate(groups):
            for handler_index, hook in enumerate(group.get("hooks", [])):
                hook_command = hook.get("command", "")
                if hook.get("type") == "command" and (ours.fullmatch(hook_command) or herdr.fullmatch(hook_command)):
                    key = f"{hooks_path}:{EVENT_LABELS[event]}:{group_index}:{handler_index}"
                    yield key, trust_hash(event, group.get("matcher"), hook)


def trust_hash(event, matcher, hook):
    """Codex hook_hash: SHA-256 of the sorted, compact JSON of the normalized hook."""
    timeout = hook.get("timeout")
    if event in SHORT_TIMEOUT_EVENTS:
        timeout = min(max(1 if timeout is None else timeout, 1), 3)
    else:
        timeout = max(600 if timeout is None else timeout, 1)
    normalized = {"type": "command", "command": hook["command"], "timeout": timeout,
                  "async": hook.get("async", False)}
    if "statusMessage" in hook:
        normalized["statusMessage"] = hook["statusMessage"]
    context_limit = hook.get("additionalContextLimit")
    if event in CONTEXT_EVENTS and context_limit is not None and context_limit != DEFAULT_CONTEXT_LIMIT:
        normalized["additionalContextLimit"] = context_limit
    identity = {"event_name": EVENT_LABELS[event], "hooks": [normalized]}
    if matcher is not None and event not in MATCHERLESS_EVENTS:
        identity["matcher"] = matcher
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(encoded.encode()).hexdigest()


def hook_states(config):
    return config.get("hooks", {}).get("state", {})


def without_hook_states(config):
    config = copy.deepcopy(config)
    config.get("hooks", {}).pop("state", None)
    if config.get("hooks") == {}:
        del config["hooks"]
    return config


def trust_codex_hooks(config_path, hooks_path, previous_settings, settings):
    """Trust managed hooks where they are and drop their trust at positions they left."""
    desired = dict(managed_hooks(settings, hooks_path))
    managed_hashes = set(desired.values()) | {
        trusted for _, trusted in managed_hooks(previous_settings, hooks_path)
    }
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    original = tomllib.loads(text)
    expected = copy.deepcopy(hook_states(original))
    for key, state in expected.items():
        if (key not in desired and key.startswith(f"{hooks_path}:")
                and state.get("trusted_hash") in managed_hashes):
            del state["trusted_hash"]
    for key, trusted in desired.items():
        expected.setdefault(key, {})["trusted_hash"] = trusted
    expected = {key: state for key, state in expected.items() if state}
    if expected == hook_states(original):
        return

    document = tomlkit.parse(text)
    if "hooks" not in document:
        document["hooks"] = tomlkit.table(is_super_table=True)
    if "state" not in document["hooks"]:
        document["hooks"]["state"] = tomlkit.table(is_super_table=True)
    table = document["hooks"]["state"]
    for key in [key for key in table if key not in expected]:
        del table[key]
    for key, state in expected.items():
        if key not in table:
            table[key] = tomlkit.table()
        for field in [field for field in table[key] if field not in state]:
            del table[key][field]
        for field, value in state.items():
            if table[key].get(field) != value:
                table[key][field] = value

    updated = tomlkit.dumps(document)
    try:
        parsed = tomllib.loads(updated)
    except tomllib.TOMLDecodeError:
        parsed = None
    if parsed is None or without_hook_states(parsed) != without_hook_states(original) or hook_states(parsed) != expected:
        sys.exit(f"Fugate: refusing to write {config_path}: the edit would change more than hook trust state.")
    config_path.write_text(updated, encoding="utf-8")


install_stop_hook(pathlib.Path(claude_settings))
codex_hooks = codex_home / "hooks.json"
trust_codex_hooks(
    codex_home / "config.toml",
    # Codex keys trust by the resolved hooks.json path.
    os.path.realpath(codex_hooks),
    *install_stop_hook(codex_hooks),
)
