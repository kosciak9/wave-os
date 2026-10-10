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
    required property var notificationService

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

    // Only the bar whose clock, battery or network opened the center shows it as open.
    readonly property bool centerHere: notificationService.centerOpen
        && (notificationService.centerScreen === null ? primary : notificationService.centerScreen === modelData)

    component NetworkWidget: WidgetButton {
        id: networkWidget

        property bool barVisible: true
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
        height: 32

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                root.notificationService.toggleAt(root.modelData, "wifi")
        }

        Image {
            anchors.verticalCenter: parent.verticalCenter
            width: 15
            height: 15
            source: Quickshell.shellDir + "/assets/" + (networkWidget.activeNetwork === null
                ? "signal-wifi-off.svg"
                : "signal-wifi-" + Math.max(1, Math.ceil(networkWidget.strength / 25)) + ".svg")
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectFit
            opacity: networkWidget.activeNetwork === null ? 0.45 : 0.8
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
                opacity: entered
                    ? (modelData.toplevels.values.length > 0 || modelData.focused ? 1 : 0.3)
                    : 0
                border.width: modelData.urgent ? 1 : 0
                border.color: Theme.waveRed
                property bool entered: false
                transform: Translate {
                    y: workspaceButton.entered ? 0 : -6
                    Behavior on y {
                        NumberAnimation { duration: Theme.slowDuration; easing.type: Easing.OutCubic }
                    }
                }
                scale: !entered ? 0.96 : workspacePointer.pressed ? 0.96 : workspacePointer.containsMouse ? 1.03 : 1

                Component.onCompleted: entered = true

                Behavior on color {
                    ColorAnimation { duration: Theme.normalDuration }
                }

                Behavior on opacity {
                    NumberAnimation { duration: Theme.normalDuration }
                }

                Behavior on scale {
                    NumberAnimation { duration: Theme.fastDuration; easing.type: Easing.OutCubic }
                }

                Behavior on border.width {
                    NumberAnimation { duration: Theme.fastDuration }
                }

                Image {
                    anchors.centerIn: parent
                    width: 15
                    height: 15
                    source: workspacesWidget.iconFor(workspaceButton.modelData.name)
                    sourceSize.width: width
                    sourceSize.height: height
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
            model: ScriptModel {
                values: [...SystemTray.items.values].filter(item => !/spotify/i.test(item.id + " " + item.title))
            }

            delegate: Rectangle {
                id: trayItem

                required property SystemTrayItem modelData

                width: 24
                height: 32
                radius: 3
                color: trayPointer.containsMouse ? Theme.sumiInk2 : "transparent"
                property bool entered: false
                opacity: entered ? 1 : 0
                transform: Translate {
                    y: trayItem.entered ? 0 : -6
                    Behavior on y {
                        NumberAnimation { duration: Theme.slowDuration; easing.type: Easing.OutCubic }
                    }
                }
                scale: !entered ? 0.96 : trayPointer.pressed ? 0.96 : trayPointer.containsMouse ? 1.03 : 1

                Component.onCompleted: entered = true

                Behavior on color {
                    ColorAnimation { duration: Theme.normalDuration }
                }

                Behavior on opacity {
                    NumberAnimation { duration: Theme.normalDuration }
                }

                Behavior on scale {
                    NumberAnimation { duration: Theme.fastDuration; easing.type: Easing.OutCubic }
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
        readonly property var battery: UPower.displayDevice

        visible: barVisible && battery.ready && battery.isPresent && battery.isLaptopBattery
        height: 32
        horizontalPadding: 4

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                root.notificationService.toggleAt(root.modelData, "")
        }

        BatteryIcon {
            id: batteryIcon
            anchors.verticalCenter: parent.verticalCenter
            level: batteryWidget.battery.percentage
            charging: batteryWidget.battery.state === UPowerDeviceState.Charging
            opacity: 0.8
        }
    }

    component Indicator: Image {
        anchors.verticalCenter: parent.verticalCenter
        width: 13
        height: 13
        sourceSize.width: width
        sourceSize.height: height
        fillMode: Image.PreserveAspectFit
        opacity: 0.8
    }

    component DndWidget: WidgetButton {
        id: dndWidget

        readonly property var service: root.notificationService

        height: 32
        horizontalPadding: 7

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                dndWidget.service.cycleMode()
        }

        Indicator {
            width: 14
            height: 14
            opacity: dndWidget.service.mode === dndWidget.service.allMode ? 0.55 : 0.9
            source: Quickshell.shellDir + "/assets/" + (dndWidget.service.mode === dndWidget.service.criticalMode ? "half-moon.svg"
                : dndWidget.service.mode === dndWidget.service.noneMode ? "bell-off.svg"
                : "bell.svg")
        }
    }

    component ClockWidget: WidgetButton {
        id: clockWidget

        height: 32
        active: root.centerHere
        activeColor: Theme.sumiInk3

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                root.notificationService.toggleAt(root.modelData, "")
        }

        SystemClock {
            id: clock
            precision: SystemClock.Minutes
        }

        Text {
            text: Qt.formatDateTime(clock.date, "HH:mm")
            color: Theme.oldWhite
            font.family: Theme.fontFamily
            font.pixelSize: 12
            font.weight: Font.Bold
        }
    }

    component NotificationsWidget: WidgetButton {
        id: notificationsWidget

        readonly property var service: root.notificationService
        readonly property bool hasNotifications: service.history.count > 0

        height: 32
        horizontalPadding: 7

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                notificationsWidget.service.clear()
        }

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16

            Indicator {
                anchors.fill: parent
                width: 16
                height: 16
                source: Quickshell.shellDir + "/assets/notifications.svg"
                opacity: notificationsWidget.hasNotifications ? 0.9 : 0.35

                Behavior on opacity {
                    NumberAnimation { duration: Theme.normalDuration }
                }
            }

            Rectangle {
                visible: notificationsWidget.hasNotifications
                x: parent.width - width / 2 - 1
                y: -width / 2 + 2
                width: 8
                height: 8
                radius: 4
                color: Theme.surimiOrange
                border.width: 1.5
                border.color: Theme.sumiInk0
            }
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
        property bool revealed: false
        opacity: revealed ? 1 : 0
        transform: Translate {
            id: revealTransform
            y: barBackground.revealed ? 0 : -8
            Behavior on y {
                NumberAnimation { duration: Theme.slowDuration; easing.type: Easing.OutCubic }
            }
        }

        Component.onCompleted: revealed = true

        Behavior on opacity {
            NumberAnimation { duration: Theme.slowDuration; easing.type: Easing.OutCubic }
        }


        Item {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4

            WorkspacesWidget {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                screenName: root.modelData.name
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: 13

                DndWidget { visible: root.primary }

                ClockWidget {}

                NotificationsWidget { visible: root.primary }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                TrayWidget {
                    visible: root.primary
                    panelWindow: root
                }

                BatteryWidget {
                    anchors.verticalCenter: parent.verticalCenter
                    barVisible: root.primary
                }

                NetworkWidget {
                    anchors.verticalCenter: parent.verticalCenter
                    barVisible: root.primary
                }
            }
        }
    }
}
