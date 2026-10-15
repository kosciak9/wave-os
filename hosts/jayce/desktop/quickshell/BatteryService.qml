pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.UPower

Scope {
    id: root

    required property var notificationService
    readonly property var battery: UPower.displayDevice
    readonly property bool present: battery.ready && battery.isPresent && battery.isLaptopBattery
    readonly property bool discharging: present && battery.state === UPowerDeviceState.Discharging
    readonly property bool low: discharging && (battery.percentage < 0.15
        || (battery.timeToEmpty > 0 && battery.timeToEmpty < 1800))
    property bool notified: false

    function updateWarning(): void {
        if (!discharging || (battery.percentage >= 0.17 && battery.timeToEmpty >= 2100))
            notified = false
        if (!low || notified)
            return
        notified = true
        const remaining = battery.timeToEmpty > 0
            ? " · " + Math.max(1, Math.floor(battery.timeToEmpty / 60)) + " min remaining" : ""
        notificationService.warnBattery(Math.floor(battery.percentage * 100) + "%" + remaining + ". Connect the charger.")
    }

    onLowChanged: Qt.callLater(updateWarning)
    onDischargingChanged: Qt.callLater(updateWarning)
    Connections {
        target: root.battery
        function onPercentageChanged() { Qt.callLater(root.updateWarning) }
        function onTimeToEmptyChanged() { Qt.callLater(root.updateWarning) }
    }
    Component.onCompleted: Qt.callLater(updateWarning)
}
