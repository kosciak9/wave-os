pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var targetScreen
    property string label: ""
    property real value: 0
    property bool muted: false

    function showVolume(data) {
        const match = data.match(/Volume:\s+([0-9.]+)/)
        if (match === null)
            return

        label = data.includes("MUTED") ? "MUTED" : "VOLUME"
        value = Math.max(0, Math.min(1, Number(match[1])))
        muted = data.includes("MUTED")
        visible = true
        hideTimer.restart()
    }

    function showBrightness(data) {
        const match = data.match(/([0-9]+)%/)
        if (match === null)
            return

        label = "BRIGHTNESS"
        value = Math.max(0, Math.min(1, Number(match[1]) / 100))
        muted = false
        visible = true
        hideTimer.restart()
    }

    screen: targetScreen
    visible: false
    color: "transparent"
    implicitWidth: 320
    implicitHeight: 76
    exclusionMode: ExclusionMode.Ignore

    anchors {
        bottom: true
    }

    margins {
        bottom: 116
    }

    mask: Region { item: background }

    IpcHandler {
        target: "osd"

        function volume(data: string): void {
            root.showVolume(data)
        }

        function brightness(data: string): void {
            root.showBrightness(data)
        }
    }

    Timer {
        id: hideTimer
        interval: 1400
        onTriggered: root.visible = false
    }

    Rectangle {
        id: background
        anchors.fill: parent
        radius: 8
        color: Theme.sumiInk0
        border.width: 1
        border.color: Theme.sumiInk3

        RowLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 14

            Text {
                Layout.preferredWidth: 76
                text: root.label
                color: root.muted ? Theme.waveRed : Theme.oldWhite
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: Font.Bold
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: Math.round(root.value * 100) + "%"
                    color: Theme.fujiWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Bold
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 7
                    radius: 4
                    color: Theme.sumiInk3

                    Rectangle {
                        width: parent.width * root.value
                        height: parent.height
                        radius: parent.radius
                        color: root.muted ? Theme.waveRed : Theme.crystalBlue

                        Behavior on width {
                            NumberAnimation { duration: 90 }
                        }
                    }
                }
            }
        }
    }
}
