pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var targetScreen
    required property var service

    screen: targetScreen
    visible: targetScreen !== null && service.centerVisible
    color: "transparent"
    implicitWidth: 424
    exclusionMode: ExclusionMode.Ignore
    focusable: true

    anchors {
        top: true
        right: true
        bottom: true
    }

    margins {
        top: 48
    }
    mask: Region { item: centerBackground }

    Rectangle {
        id: centerBackground
        anchors.fill: parent
        color: Theme.sumiInk0
        focus: root.visible

        Keys.onEscapePressed: root.service.centerVisible = false

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: "Notifications"
                    color: Theme.fujiWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Bold
                }

                WidgetButton {
                    active: root.service.dnd
                    activeColor: Theme.waveBlue2
                    horizontalPadding: 7
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton)
                            root.service.dnd = !root.service.dnd
                    }

                    Image {
                        width: 14
                        height: 14
                        source: Quickshell.shellDir + "/assets/half-moon.svg"
                    }
                }

                WidgetButton {
                    horizontalPadding: 7
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton)
                            root.service.clearAll()
                    }

                    Image {
                        width: 14
                        height: 14
                        source: Quickshell.shellDir + "/assets/list-select.svg"
                    }
                }

                WidgetButton {
                    horizontalPadding: 7
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton)
                            root.service.centerVisible = false
                    }

                    Image {
                        width: 14
                        height: 14
                        source: Quickshell.shellDir + "/assets/xmark.svg"
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.sumiInk3
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                    anchors.centerIn: parent
                    visible: root.service.count === 0
                    text: "No notifications"
                    color: Theme.fujiGray
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.weight: Font.Bold
                }

                Flickable {
                    id: notificationScroll
                    anchors.fill: parent
                    visible: root.service.count > 0
                    clip: true
                    contentWidth: width
                    contentHeight: notificationList.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                    }

                    Column {
                        id: notificationList
                        width: notificationScroll.width - 8
                        spacing: 8

                        Repeater {
                            model: ScriptModel {
                                values: [...root.service.notifications.values].reverse()
                            }

                            delegate: NotificationCard {
                                required property var modelData
                                width: notificationList.width
                                notification: modelData
                            }
                        }
                    }
                }
            }
        }
    }
}
