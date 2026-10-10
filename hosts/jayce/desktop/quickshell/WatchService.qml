pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Bluetooth

// The paired InfiniTime as BlueZ reports it; `wave watch` keeps it connected.
Scope {
    id: root

    readonly property var device: {
        for (const candidate of Bluetooth.devices.values) {
            if (candidate.name === "InfiniTime" && (candidate.paired || candidate.bonded))
                return candidate
        }
        return null
    }
    readonly property bool known: device !== null
    readonly property bool connected: known && device.connected
    readonly property int battery: connected && device.batteryAvailable ? Math.round(device.battery * 100) : -1
    readonly property string status: !known ? "Not paired"
        : connected ? (battery >= 0 ? battery + "%" : "Connected")
        : "Disconnected"
}
