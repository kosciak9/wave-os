pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Networking
import Quickshell.Services.SystemTray
import Quickshell.Services.UPower
import Quickshell.Widgets
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var modelData
    required property bool primary

    screen: modelData
    color: "transparent"
    implicitHeight: 48
    exclusiveZone: 48
    exclusionMode: ExclusionMode.Normal

    anchors {
        top: true
        left: true
        right: true
    }

    mask: Region { item: barBackground }

    component NetworkWidget: WidgetButton {
        id: networkWidget

        property bool barVisible: true
        property int mode: 0
        readonly property var wifiDevice: {
            const devices = Networking.devices.values
            for (const device of devices) {
                if (device.type === DeviceType.Wifi)
                    return device
            }
            return null
        }
        readonly property var activeNetwork: {
            if (wifiDevice === null)
                return null
            const networks = wifiDevice.networks.values
            for (const network of networks) {
                if (network.connected)
                    return network
            }
            return null
        }
        readonly property int strength: activeNetwork === null ? 0 : Math.round(activeNetwork.signalStrength * 100)

        visible: barVisible && wifiDevice !== null && Networking.wifiEnabled
        inactiveOpacity: activeNetwork === null ? 0.5 : 1
        spacing: 5

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                mode = (mode + 1) % 3
        }

        Image {
            width: 15
            height: 15
            source: Quickshell.shellDir + (networkWidget.activeNetwork === null ? "/assets/wifi-off.svg" : "/assets/wifi.svg")
            fillMode: Image.PreserveAspectFit
            opacity: 0.8
        }

        Text {
            visible: networkWidget.activeNetwork === null || networkWidget.mode !== 0
            text: networkWidget.activeNetwork === null
                ? "Not connected"
                : networkWidget.mode === 1
                    ? networkWidget.strength + "%"
                    : networkWidget.activeNetwork.name + " (" + networkWidget.strength + "%)"
            color: Theme.oldWhite
            font.family: Theme.fontFamily
            font.pixelSize: 11
            font.weight: Font.Bold
        }
    }

    component WorkspacesWidget: Row {
        id: workspacesWidget

        required property string screenName
        spacing: 4

        function iconFor(name) {
            const icons = {
                web: "globe.svg",
                code: "code.svg",
                chat: "chat-bubble.svg",
                notes: "book.svg",
                music: "music-double-note.svg"
            }
            return Quickshell.shellDir + "/assets/" + (icons[name] || "square.svg")
        }

        Connections {
            target: Hyprland

            function onRawEvent(event) {
                if (event.name === "workspaceorder")
                    Hyprland.refreshWorkspaces()
            }
        }

        Repeater {
            model: ScriptModel {
                values: [...Hyprland.workspaces.values]
                    .filter(workspace => workspace.id > 0
                        && workspace.monitor !== null
                        && workspace.monitor.name === workspacesWidget.screenName)
                    .sort((left, right) => (left.lastIpcObject.index || left.id) - (right.lastIpcObject.index || right.id))
            }

            delegate: Rectangle {
                id: workspaceButton

                required property HyprlandWorkspace modelData

                width: 35
                height: 28
                radius: 3
                color: modelData.focused
                    ? Theme.sumiInk3
                    : workspacePointer.containsMouse ? Theme.sumiInk2 : "transparent"
                opacity: modelData.toplevels.values.length > 0 || modelData.focused ? 1 : 0.3
                border.width: modelData.urgent ? 1 : 0
                border.color: Theme.waveRed

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                Behavior on opacity {
                    NumberAnimation { duration: 150 }
                }

                Image {
                    anchors.centerIn: parent
                    width: 15
                    height: 15
                    source: workspacesWidget.iconFor(workspaceButton.modelData.name)
                    fillMode: Image.PreserveAspectFit
                }

                MouseArea {
                    id: workspacePointer
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: workspaceButton.modelData.activate()
                }
            }
        }
    }

    component TrayWidget: Row {
        id: trayWidget

        required property var panelWindow
        spacing: 4

        Repeater {
            model: SystemTray.items

            delegate: Rectangle {
                id: trayItem

                required property SystemTrayItem modelData

                width: 24
                height: 32
                radius: 3
                color: trayPointer.containsMouse ? Theme.sumiInk2 : "transparent"

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                IconImage {
                    anchors.centerIn: parent
                    width: 16
                    height: 16
                    source: trayItem.modelData.icon
                    opacity: 0.8
                }

                MouseArea {
                    id: trayPointer
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    hoverEnabled: true

                    onClicked: function(mouse) {
                        if (mouse.button === Qt.MiddleButton) {
                            trayItem.modelData.secondaryActivate()
                            return
                        }

                        if (trayItem.modelData.hasMenu || trayItem.modelData.onlyMenu || mouse.button === Qt.RightButton) {
                            const position = trayWidget.panelWindow.itemPosition(trayItem)
                            trayItem.modelData.display(
                                trayWidget.panelWindow,
                                Math.round(position.x),
                                Math.round(position.y + trayItem.height)
                            )
                            return
                        }

                        trayItem.modelData.activate()
                    }

                    onWheel: function(wheel) {
                        trayItem.modelData.scroll(wheel.angleDelta.y, false)
                        wheel.accepted = true
                    }
                }
            }
        }
    }

    component BatteryWidget: WidgetButton {
        id: batteryWidget

        property bool barVisible: true
        property int mode: 0
        readonly property var battery: UPower.displayDevice
        readonly property int percentage: Math.floor(battery.percentage * 100)
        readonly property bool charging: battery.state === UPowerDeviceState.Charging

        visible: barVisible && battery.ready && battery.isPresent && battery.isLaptopBattery
        spacing: 5

        function iconPath() {
            if (charging)
                return Quickshell.shellDir + "/assets/battery-charging.svg"
            if (percentage < 10)
                return Quickshell.shellDir + "/assets/battery-empty-red.svg"
            if (percentage < 15)
                return Quickshell.shellDir + "/assets/battery-25-red.svg"
            if (percentage < 25)
                return Quickshell.shellDir + "/assets/battery-25.svg"
            if (percentage < 50)
                return Quickshell.shellDir + "/assets/battery-50.svg"
            if (percentage < 75)
                return Quickshell.shellDir + "/assets/battery-75.svg"
            return Quickshell.shellDir + "/assets/battery-full.svg"
        }

        function formatDuration(seconds) {
            if (seconds <= 0)
                return ""
            const hours = Math.floor(seconds / 3600)
            const minutes = Math.floor((seconds % 3600) / 60)
            return hours + "h " + minutes + "m"
        }

        function statusText() {
            if (battery.state === UPowerDeviceState.Charging) {
                const remaining = formatDuration(battery.timeToFull)
                return remaining ? remaining + " to full" : percentage + "%"
            }
            if (battery.state === UPowerDeviceState.Discharging) {
                const remaining = formatDuration(battery.timeToEmpty)
                return remaining ? remaining + " left" : percentage + "%"
            }
            return percentage + "%"
        }

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                mode = (mode + 1) % 2
        }

        Image {
            width: 18
            height: 18
            source: batteryWidget.iconPath()
            fillMode: Image.PreserveAspectFit
            opacity: 0.8
        }

        Text {
            text: batteryWidget.mode === 0
                ? batteryWidget.percentage + "%"
                : batteryWidget.statusText()
            color: batteryWidget.percentage < 15 ? Theme.waveRed : Theme.oldWhite
            font.family: Theme.fontFamily
            font.pixelSize: 11
            font.weight: Font.Bold
        }
    }

    component ClockWidget: WidgetButton {
        id: clockWidget

        property int mode: 0

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                mode = (mode + 1) % 2
        }

        SystemClock {
            id: clock
            precision: SystemClock.Minutes
        }

        Text {
            text: Qt.formatDateTime(
                clock.date,
                clockWidget.mode === 0 ? "HH:mm" : "dddd, MMMM d, yyyy"
            )
            color: Theme.oldWhite
            font.family: Theme.fontFamily
            font.pixelSize: 11
            font.weight: Font.Bold
        }
    }

    Rectangle {
        id: barBackground
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            margins: 8
        }
        height: 32
        radius: 6
        color: Theme.sumiInk0

        Item {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                NetworkWidget { barVisible: root.primary }
            }

            WorkspacesWidget {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                screenName: root.modelData.name
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                TrayWidget {
                    visible: root.primary
                    panelWindow: root
                }

                BatteryWidget { barVisible: root.primary }

                ClockWidget {}
            }
        }
    }
}
