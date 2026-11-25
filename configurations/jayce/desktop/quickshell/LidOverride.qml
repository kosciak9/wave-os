pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Mirrors `wave display lid-override`: the daemon pushes every change, so the
// subscription is restarted only when the daemon itself goes away.
Scope {
    id: root

    property bool connected: false
    property bool available: false
    property bool active: false
    property bool pending: false
    property string error: ""
    readonly property bool shown: connected && (available || active)

    function toggle(): void {
        if (!connected || pending)
            return
        pending = true
        error = ""
        command.running = true
    }

    Process {
        id: subscription
        command: ["wave", "display", "lid-override", "watch"]
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    const status = JSON.parse(line)
                    root.available = status.available === true
                    root.active = status.active === true
                    root.connected = true
                } catch (error) {
                    root.connected = false
                }
            }
        }
        stderr: StdioCollector {}

        onExited: {
            root.connected = false
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
        command: ["wave", "display", "lid-override", "toggle"]
        stdout: StdioCollector {}
        stderr: StdioCollector { id: commandError }

        onExited: function(exitCode, exitStatus) {
            root.pending = false
            if (exitStatus !== 0 || exitCode !== 0)
                root.error = commandError.text.trim() || "Could not switch the laptop screen."
        }
    }
}
