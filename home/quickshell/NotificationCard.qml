pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Widgets
import "Theme.js" as Theme

Rectangle {
    id: root

    required property var notification
    property bool compact: false

    readonly property color accentColor: notification.urgency === NotificationUrgency.Critical
        ? Theme.waveRed
        : notification.urgency === NotificationUrgency.Low ? Theme.fujiGray : Theme.crystalBlue
    readonly property string iconSource: {
        if (notification.image)
            return notification.image

        const icon = notification.appIcon
        if (!icon)
            return ""
        if (icon.startsWith("/") || icon.startsWith("file:") || icon.startsWith("image://"))
            return icon.startsWith("/") ? "file://" + icon : icon
        return Quickshell.iconPath(icon, true)
    }

    implicitHeight: cardLayout.implicitHeight + 24
    radius: 6
    color: Theme.sumiInk1
    clip: true

    Rectangle {
        anchors {
            top: parent.top
            bottom: parent.bottom
            left: parent.left
        }
        width: 3
        color: root.accentColor
    }

    RowLayout {
        id: cardLayout
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            margins: 12
        }
        spacing: 12

        Item {
            visible: root.iconSource !== ""
            Layout.preferredWidth: visible ? 32 : 0
            Layout.preferredHeight: visible ? 32 : 0
            Layout.alignment: Qt.AlignTop

            IconImage {
                anchors.fill: parent
                source: root.iconSource
                opacity: 0.8
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: (root.notification.appName || "Unknown").toUpperCase()
                    color: Theme.fujiGray
                    elide: Text.ElideRight
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.weight: Font.Bold
                }

                Rectangle {
                    Layout.preferredWidth: 20
                    Layout.preferredHeight: 20
                    radius: 4
                    color: closePointer.containsMouse ? Theme.sumiInk3 : "transparent"

                    Image {
                        anchors.centerIn: parent
                        width: 10
                        height: 10
                        source: Quickshell.shellDir + "/assets/xmark.svg"
                    }

                    MouseArea {
                        id: closePointer
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.notification.dismiss()
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.notification.summary
                color: Theme.fujiWhite
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                maximumLineCount: root.compact ? 2 : 4
                font.family: Theme.fontFamily
                font.pixelSize: 12
                font.weight: Font.Bold
            }

            Text {
                visible: text !== ""
                Layout.fillWidth: true
                text: root.notification.body
                color: Theme.oldWhite
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                maximumLineCount: root.compact ? 4 : 8
                font.family: Theme.fontFamily
                font.pixelSize: 11
                font.weight: Font.Normal
            }

            RowLayout {
                visible: root.notification.actions.length > 0
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 4

                Repeater {
                    model: root.notification.actions

                    delegate: Rectangle {
                        id: actionButton

                        required property var modelData

                        Layout.preferredWidth: actionLabel.implicitWidth + 20
                        Layout.preferredHeight: 24
                        radius: 4
                        color: actionPointer.containsMouse ? Theme.waveBlue1 : Theme.sumiInk3

                        Text {
                            id: actionLabel
                            anchors.centerIn: parent
                            text: actionButton.modelData.text
                            color: Theme.oldWhite
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            font.weight: Font.Bold
                        }

                        MouseArea {
                            id: actionPointer
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: actionButton.modelData.invoke()
                        }
                    }
                }

                Item { Layout.fillWidth: true }
            }
        }
    }
}
