pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property string state: ""
    property string error: ""
    readonly property bool checking: checkProcess.running
    readonly property bool available: state === "update_available" && error.length === 0
    readonly property string status: checking ? "Checking…"
        : error || (state === "current" ? "Up to date"
        : state === "update_available" ? "Update ready"
        : state === "update_awaiting_ci" ? "Waiting for CI"
        : state === "update_failed_ci" ? "CI failed"
        : state === "active_revision_unknown" ? "Active revision unknown"
        : state === "operation_in_progress" ? "Wave is busy"
        : "Not checked")

    function refresh(): void {
        if (!checking)
            checkProcess.running = true
    }

    Process {
        id: checkProcess
        command: ["wave", "check", "--json"]
        running: true
        stdout: StdioCollector { id: output }
        stderr: StdioCollector {}
        onExited: function(exitCode, exitStatus) {
            root.error = "Could not check updates"
            if (exitStatus !== 0 || exitCode < 0 || exitCode > 5)
                return
            try {
                const data = JSON.parse(output.text)
                if (["current", "update_available", "update_awaiting_ci", "update_failed_ci", "active_revision_unknown", "operation_in_progress"].indexOf(data.status) < 0)
                    return
                root.state = data.status
                root.error = ""
            } catch (error) {}
        }
    }

    Timer {
        interval: root.state === "operation_in_progress" && root.error.length === 0 ? 5000 : 300000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
