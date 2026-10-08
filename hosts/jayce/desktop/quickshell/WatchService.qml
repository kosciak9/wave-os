pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool known: false
    property bool connected: false
    property int battery: -1
    readonly property string status: !known ? "Checking…"
        : connected ? (battery >= 0 ? battery + "%" : "Connected")
        : "Disconnected"

    function refresh(): void {
        batteryFile.reload()
    }

    Component.onCompleted: refresh()

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    FileView {
        id: batteryFile
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/itd-health/battery"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const level = parseInt(text().trim(), 10)
            root.known = true
            root.connected = !isNaN(level) && level >= 0
            root.battery = root.connected ? level : -1
        }
        onLoadFailed: {
            root.known = false
            root.connected = false
            root.battery = -1
        }
    }
}
