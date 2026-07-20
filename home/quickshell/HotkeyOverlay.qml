pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var targetScreen

    screen: targetScreen
    visible: false
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    focusable: true

    anchors {
        top: true
        right: true
        bottom: true
        left: true
    }

    mask: Region { item: backdrop }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "custom" && event.data === "wave:hotkey-overlay")
                root.visible = !root.visible
        }
    }

    Rectangle {
        id: backdrop
        anchors.fill: parent
        color: "#99000000"
        focus: root.visible

        Keys.onEscapePressed: root.visible = false

        MouseArea {
            anchors.fill: parent
            onClicked: root.visible = false
        }

        Rectangle {
            id: card
            anchors.centerIn: parent
            width: Math.min(parent.width - 64, 920)
            height: Math.min(parent.height - 96, content.implicitHeight + 48)
            radius: 8
            color: Theme.sumiInk0
            border.width: 1
            border.color: Theme.sumiInk3

            MouseArea {
                anchors.fill: parent
                onClicked: function(mouse) { mouse.accepted = true }
            }

            ColumnLayout {
                id: content
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            text: "Desktop shortcuts"
                            color: Theme.fujiWhite
                            font.family: Theme.fontFamily
                            font.pixelSize: 20
                            font.weight: Font.Bold
                        }

                        Text {
                            text: "Super is the primary modifier"
                            color: Theme.fujiGray
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                        }
                    }

                    Text {
                        text: "Esc to close"
                        color: Theme.oldWhite
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.sumiInk3
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: card.width >= 700 ? 2 : 1
                    columnSpacing: 28
                    rowSpacing: 7

                    Repeater {
                        model: [
                            { keys: "Return", action: "Open terminal" },
                            { keys: "Space", action: "Open launcher" },
                            { keys: "W", action: "Close window" },
                            { keys: "V", action: "Toggle floating" },
                            { keys: "H / J / K / L", action: "Focus left / down / up / right" },
                            { keys: "Ctrl + H / J / K / L", action: "Move window or column" },
                            { keys: "Shift + H / J / K / L", action: "Focus monitor" },
                            { keys: "Shift + Ctrl + H / J / K / L", action: "Move to monitor" },
                            { keys: "U / I", action: "Next / previous workspace" },
                            { keys: "Ctrl + U / I", action: "Move to workspace" },
                            { keys: "Shift + U / I", action: "Reorder workspace" },
                            { keys: "1 ... 9", action: "Focus workspace" },
                            { keys: "Ctrl + 1 ... 9", action: "Move to workspace" },
                            { keys: "[ / ]", action: "Consume or expel window" },
                            { keys: ", / .", action: "Consume / expel from column" },
                            { keys: "R", action: "Cycle column width" },
                            { keys: "Shift + R", action: "Cycle window height" },
                            { keys: "Ctrl + R", action: "Reset window heights" },
                            { keys: "F", action: "Maximize column" },
                            { keys: "Shift + F", action: "Toggle fullscreen" },
                            { keys: "C", action: "Center column" },
                            { keys: "- / =", action: "Resize column" },
                            { keys: "Shift + - / =", action: "Resize window height" },
                            { keys: "Print", action: "Screenshot region" },
                            { keys: "Ctrl / Alt + Print", action: "Screenshot output / window" },
                            { keys: "Alt + L", action: "Lock session" },
                            { keys: "Shift + P", action: "Power off displays" },
                            { keys: "Shift + E", action: "Quit session" }
                        ]

                        delegate: RowLayout {
                            id: shortcut

                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 10

                            Rectangle {
                                Layout.preferredWidth: 180
                                Layout.preferredHeight: 25
                                radius: 4
                                color: Theme.sumiInk2
                                border.width: 1
                                border.color: Theme.sumiInk3

                                Text {
                                    anchors.centerIn: parent
                                    text: shortcut.modelData.keys
                                    color: Theme.carpYellow
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: shortcut.modelData.action
                                color: Theme.oldWhite
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }
    }
}
