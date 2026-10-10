pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Mirrors `wave caffeinate`: systemd pushes every state change of the unit,
// so the subscription is restarted only when the watcher itself exits.
Scope {
    id: root

    property bool known: false
    property bool active: false
    property bool transitioning: false
    property bool commandPending: false
    property string stateError: ""
    property string commandError: ""
    readonly property bool pending: commandPending || transitioning
    readonly property string error: commandError || stateError

    function toggle(): void {
        if (!known || pending)
            return
        commandError = ""
        commandPending = true
        command.running = true
    }

    Process {
        id: subscription
        command: ["wave", "caffeinate", "watch"]
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    const status = JSON.parse(line)
                    root.known = true
                    root.active = status.active === true
                    root.transitioning = status.state === "activating"
                        || status.state === "deactivating"
                        || status.state === "reloading"
                    root.stateError = status.state === "failed" ? "Caffeinate service failed. Click to retry." : ""
                } catch (error) {
                    root.known = false
                    root.stateError = "Cannot read caffeinate state."
                }
            }
        }
        stderr: StdioCollector {}

        onExited: {
            root.known = false
            root.stateError = "Cannot follow caffeinate state."
            resubscribe.start()
        }
    }

    Timer {
        id: resubscribe
        interval: 2000
        onTriggered: subscription.running = true
    }

    Process {
        id: command
        command: ["wave", "caffeinate", "toggle"]
        stdout: StdioCollector {}
        stderr: StdioCollector { id: commandOutput }

        onExited: function(exitCode, exitStatus) {
            root.commandPending = false
            if (exitStatus !== 0 || exitCode !== 0)
                root.commandError = commandOutput.text.trim() || "Could not switch caffeinate. Click to retry."
        }
    }
}
