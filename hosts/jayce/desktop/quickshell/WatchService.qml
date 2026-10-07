pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    readonly property string itctl: Quickshell.env("WAVE_ITCTL") || ""
    property bool known: false
    property bool connected: false
    property int battery: -1
    readonly property string status: !known ? "Checking…"
        : connected ? (battery >= 0 ? battery + "%" : "Connected")
        : "Disconnected"

    function refresh(): void {
        if (itctl.length === 0 || query.running)
            return
        query.running = true
    }

    Component.onCompleted: refresh()

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // itd opens its socket only after reaching the watch and GATT reads fail while
    // it is reconnecting, so a successful battery read doubles as the connection check.
    Process {
        id: query
        command: ["timeout", "10", root.itctl, "get", "battery"]
        stdout: StdioCollector {
            id: batteryOutput
            waitForEnd: true
        }
        stderr: StdioCollector {}

        onExited: function(exitCode, exitStatus) {
            const level = parseInt(batteryOutput.text.trim(), 10)
            root.known = true
            root.connected = exitStatus === 0 && exitCode === 0 && !isNaN(level)
            root.battery = root.connected ? level : -1
        }
    }
}
