import importlib.util
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path


SCRIPT = Path(__file__).parent / "scripts" / "display-reconciler.py"
SPEC = importlib.util.spec_from_file_location("display_reconciler", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


MONITORS = [
    {"name": "eDP-1", "description": "Laptop, Panel", "focused": True,
     "activeWorkspace": {"id": 1}},
    {"name": "DP-1", "description": "Dell, P2720D", "focused": False,
     "activeWorkspace": {"id": 2}},
]


class DisplayStateTests(unittest.TestCase):
    def test_automatic_evacuation_preserves_desired_owner(self):
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "DP-1",
                                   "desired_identity": "description:Dell P2720D"}},
            "last_active": {},
        })
        ownership.mappings(MONITORS)
        ownership.move_event(2, "eDP-1")
        ownership.monitor_removed("DP-1")
        ownership.flush(time.monotonic() + 1)
        self.assertEqual(
            ownership.data["workspaces"]["2"]["desired_identity"],
            "description:Dell P2720D",
        )

    def test_deliberate_move_commits_resolved_identity(self):
        ownership = MODULE.Ownership({"workspaces": {}, "last_active": {}})
        ownership.mappings(MONITORS)
        ownership.workspace(2, current="eDP-1")
        ownership.move_event(2, "DP-1")
        ownership.flush(time.monotonic() + 1)
        self.assertEqual(
            ownership.data["workspaces"]["2"]["desired_identity"],
            "description:Dell P2720D",
        )

    def test_generated_move_event_arriving_later_preserves_desired(self):
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "eDP-1",
                                   "desired_identity": "description:Dell P2720D"}},
            "last_active": {},
        })
        ownership.mappings(MONITORS)
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        reconciler.ownership = ownership
        reconciler.generated["2"] = ("DP-1", time.monotonic())
        self.assertTrue(reconciler.consume_generated("2", "DP-1"))
        ownership.move_event(2, "DP-1", generated=True)
        ownership.flush(time.monotonic() + 1)
        self.assertEqual(
            ownership.data["workspaces"]["2"]["desired_identity"],
            "description:Dell P2720D",
        )

    def test_connector_rename_restores_by_description(self):
        monitors = [{"name": "DP-9", "description": "Dell,P2720D"}]
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "DP-1",
                                   "desired_identity": "description:Dell P2720D"}},
            "last_active": {},
        })
        ownership.mappings(monitors)
        self.assertEqual(ownership.identity_to_connector["description:Dell P2720D"], "DP-9")

    def test_duplicate_descriptions_use_connector_fallback(self):
        monitors = [{"name": "DP-1", "description": "same,screen"},
                    {"name": "DP-2", "description": "same screen"}]
        ownership = MODULE.Ownership()
        ownership.mappings(monitors)
        self.assertEqual(ownership.connector_to_identity["DP-1"], "connector:DP-1")

    def test_target_selection_is_stable(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        monitors = [{"name": "eDP-1"}, {"name": "DP-2", "focused": False},
                    {"name": "HDMI-A-1", "focused": True}]
        self.assertEqual(reconciler.target_external(monitors), "HDMI-A-1")
        reconciler.last_external = "DP-2"
        self.assertEqual(reconciler.target_external(monitors), "DP-2")

    def test_target_selection_follows_renumbered_preferred_identity(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        reconciler.preferred_external_identity = "description:Dell P2720D"
        monitors = [{"name": "DP-9", "description": "Dell,P2720D"},
                    {"name": "HDMI-A-1", "description": "Other"}]
        reconciler.ownership.mappings(monitors)
        self.assertEqual(reconciler.target_external(monitors), "DP-9")

    def test_atomic_state_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            ownership = MODULE.Ownership()
            ownership.workspace(7, current="DP-1", desired="description:Panel")
            MODULE.save_state(path, ownership)
            loaded = MODULE.load_state(path)
            self.assertEqual(loaded.data["workspaces"]["7"]["desired_identity"],
                             "description:Panel")

    def test_event_parser_and_partial_buffer(self):
        self.assertEqual(MODULE.parse_event("moveworkspacev2>>2,name,DP-1"),
                         ("moveworkspacev2", ["2", "name", "DP-1"]))
        buffer = MODULE.EventBuffer()
        self.assertEqual(buffer.feed("focusedmonv2>>DP"), [])
        self.assertEqual(buffer.feed("-1,desc\nmonitorremovedv2>>3,DP-1,x\n"),
                         ["focusedmonv2>>DP-1,desc", "monitorremovedv2>>3,DP-1,x"])
        decoder = MODULE.new_event_decoder()
        buffer = MODULE.EventBuffer()
        text = "workspacev2>>2,é\n"
        encoded = text.encode()
        self.assertEqual(buffer.feed(decoder.decode(encoded[:15], final=False)), [])
        self.assertEqual(buffer.feed(decoder.decode(encoded[15:], final=False)),
                         [text.rstrip("\n")])

    def test_ordered_evacuating_events_do_not_refresh_before_removal(self):
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "DP-1",
                                   "desired_identity": "description:Dell P2720D"}},
            "last_active": {"description:Dell P2720D": 2},
        })
        ownership.mappings(MONITORS)
        self.assertTrue(MODULE.event_refreshes_snapshot("workspacev2"))
        # The daemon defers this snapshot; the move/removal boundary wins.
        ownership.move_event(2, "eDP-1")
        ownership.monitor_removed("DP-1")
        ownership.flush(time.monotonic() + 1)
        self.assertEqual(ownership.data["workspaces"]["2"]["desired_identity"],
                         "description:Dell P2720D")
        self.assertEqual(ownership.data["last_active"]["description:Dell P2720D"], 2)

    def test_reconnect_requests_reconciliation(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        with mock.patch.object(reconciler, "reconcile") as reconcile:
            reconciler.socket_connected()
        reconcile.assert_called_once_with()

    def test_denied_suspend_backoff_is_bounded_and_resettable(self):
        self.assertEqual(MODULE.next_suspend_retry_delay(1), 2)
        self.assertEqual(MODULE.next_suspend_retry_delay(20), 30)

    def test_raw_incomplete_utf8_is_not_eof(self):
        decoder = MODULE.new_event_decoder()
        eof, text = MODULE.decode_event_bytes(decoder, "é".encode()[:1])
        self.assertFalse(eof)
        self.assertEqual(text, "")
        eof, text = MODULE.decode_event_bytes(decoder, "é".encode()[1:])
        self.assertFalse(eof)
        self.assertEqual(text, "é")
        eof, text = MODULE.decode_event_bytes(decoder, b"")
        self.assertTrue(eof)
        self.assertEqual(text, "")

    def test_due_suspend_retry_runs_only_when_closed_and_headless(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        reconciler.suspend_retry_at = time.monotonic() - 1
        with mock.patch.object(MODULE, "json_command", return_value=[{"name": "eDP-1"}]), \
                mock.patch.object(MODULE, "lid_state", return_value="closed"), \
                mock.patch.object(reconciler, "close") as close:
            reconciler.retry_suspend_if_due()
        close.assert_called_once_with()

    def test_suspend_retry_not_due_or_topology_changed_is_cancelled(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        reconciler.suspend_retry_at = time.monotonic() + 100
        with mock.patch.object(MODULE, "json_command", return_value=[{"name": "eDP-1"}]), \
                mock.patch.object(MODULE, "lid_state", return_value="closed"), \
                mock.patch.object(reconciler, "close") as close:
            reconciler.retry_suspend_if_due()
        close.assert_not_called()
        self.assertGreater(reconciler.suspend_retry_at, time.monotonic())
        reconciler.suspend_retry_at = time.monotonic() - 1
        with mock.patch.object(MODULE, "json_command", return_value=[
            {"name": "eDP-1"}, {"name": "DP-1"}
        ]), mock.patch.object(MODULE, "lid_state", return_value="closed"):
            reconciler.retry_suspend_if_due()
        self.assertEqual(reconciler.suspend_retry_at, 0.0)

    def test_first_close_without_external_only_selects_suspend(self):
        self.assertEqual(MODULE.lid_policy([{"name": "eDP-1"}]), ("suspend", None))

    def test_open_reconcile_with_missing_internal_selects_open_path(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        with mock.patch.object(reconciler, "snapshot", return_value=[{"name": "DP-1"}]), \
                mock.patch.object(MODULE, "lid_state", return_value="open"), \
                mock.patch.object(reconciler, "open") as open_action:
            reconciler.reconcile()
        open_action.assert_called_once_with()

    def test_pre_add_restoration_move_keeps_same_stable_owner(self):
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "eDP-1",
                                   "desired_identity": "description:Dell P2720D"}},
            "last_active": {},
        })
        ownership.mappings(MONITORS)
        ownership.move_event(2, "DP-9")
        ownership.monitor_added("DP-9", "description:Dell P2720D")
        ownership.flush(time.monotonic() + 1)
        self.assertEqual(ownership.data["workspaces"]["2"]["desired_identity"],
                         "description:Dell P2720D")

    def test_rapid_readd_keeps_evacuated_owner_classification(self):
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "DP-1",
                                   "desired_identity": "description:Dell P2720D"}},
            "last_active": {},
        })
        ownership.mappings(MONITORS)
        ownership.move_event(2, "eDP-1")
        ownership.monitor_removed("DP-1")
        ownership.monitor_added("DP-1", "description:Dell P2720D")
        ownership.flush(time.monotonic() + 1)
        self.assertEqual(ownership.data["workspaces"]["2"]["desired_identity"],
                         "description:Dell P2720D")

    def test_last_active_requires_workspace_on_target(self):
        ownership = MODULE.Ownership({
            "workspaces": {"2": {"current_connector": "DP-1"}},
            "last_active": {"description:Dell P2720D": 2},
        })
        ownership.mappings(MONITORS)
        self.assertEqual(MODULE.last_active_candidate(ownership, "DP-1"), "2")
        ownership.data["workspaces"]["2"]["current_connector"] = "eDP-1"
        self.assertIsNone(MODULE.last_active_candidate(ownership, "DP-1"))

    def test_saved_active_workspace_wins_over_reconnect_default(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        stable = "description:Dell P2720D"
        reconciler.ownership.data["last_active"][stable] = 2
        reconciler.begin_monitor_reconnect("DP-9", stable)
        monitors = [{"name": "DP-9", "description": "Dell,P2720D",
                     "focused": False, "activeWorkspace": {"id": 9}}]
        with mock.patch.object(MODULE, "json_command", side_effect=[
            monitors, [{"id": 9, "monitor": "DP-9"}]
        ]):
            reconciler.snapshot()
        self.assertEqual(reconciler.ownership.data["last_active"][stable], 2)
        reconciler.finish_monitor_reconnect(stable)

    def test_reload_protects_persisted_internal_identity_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            state = MODULE.Ownership({
                "workspaces": {"2": {"current_connector": "DP-1"}},
                "last_active": {"description:Laptop Panel": 2},
                "outputs": {"connector_to_identity": {
                    "eDP-1": "description:Laptop Panel",
                }},
            })
            MODULE.save_state(path, state)
            reconciler = MODULE.Reconciler(path)
            reconciler.begin_topology_transition()
            self.assertEqual(reconciler.pending_active_restore[
                "description:Laptop Panel"], 2)

    def test_disconnected_identity_remains_known_but_not_live(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            ownership = MODULE.Ownership()
            ownership.mappings(MONITORS)
            ownership.data["last_active"]["description:Laptop Panel"] = 2
            MODULE.save_state(path, ownership)
            ownership.mappings([MONITORS[1]])
            MODULE.save_state(path, ownership)
            loaded = MODULE.load_state(path)
            self.assertEqual(
                loaded.data["outputs"]["connector_to_identity"]["eDP-1"],
                "description:Laptop Panel",
            )
            self.assertEqual(loaded.connector_to_identity, {})
            restored = MODULE.Reconciler(path)
            restored.begin_topology_transition()
            self.assertEqual(
                restored.pending_active_restore["description:Laptop Panel"],
                2,
            )

    def test_disconnect_transition_protects_backup_active_workspace(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        stable = "description:Dell P2720D"
        reconciler.ownership.data["last_active"][stable] = 2
        reconciler.begin_topology_transition()
        monitors = [{"name": "DP-1", "description": "Dell,P2720D",
                     "activeWorkspace": {"id": 9}}]
        with mock.patch.object(MODULE, "json_command", side_effect=[
            monitors, [{"id": 9, "monitor": "DP-1"}]
        ]):
            reconciler.snapshot()
        self.assertEqual(reconciler.ownership.data["last_active"][stable], 2)
        reconciler.finish_topology_transition()

    def test_workspacev2_refreshes_snapshot(self):
        self.assertTrue(MODULE.event_refreshes_snapshot("workspacev2"))
        self.assertTrue(MODULE.event_refreshes_snapshot("focusedmonv2"))
        self.assertFalse(MODULE.event_refreshes_snapshot("monitoraddedv2"))

    def test_closed_steady_state_still_restores_external_outputs(self):
        reconciler = MODULE.Reconciler(tempfile.mktemp())
        monitors = [{"name": "DP-1", "description": "Dell,P2720D"}]
        with mock.patch.object(reconciler, "snapshot", return_value=monitors), \
                mock.patch.object(reconciler, "restore_outputs") as restore:
            reconciler.close()
        restore.assert_called_once_with(monitors)


if __name__ == "__main__":
    unittest.main()
