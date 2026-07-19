pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

PanelWindow {
    id: root

    required property var targetScreen
    required property var service

    screen: targetScreen
    visible: targetScreen !== null && !service.centerVisible && popupColumn.implicitHeight > 0
    color: "transparent"
    implicitWidth: 416
    implicitHeight: popupColumn.implicitHeight > 0 ? popupColumn.implicitHeight + 16 : 1
    exclusionMode: ExclusionMode.Ignore

    anchors {
        top: true
        right: true
    }

    margins {
        top: 48
    }
    mask: Region { item: popupColumn }

    Column {
        id: popupColumn
        anchors {
            top: parent.top
            right: parent.right
            margins: 8
        }
        width: 400
        spacing: 8

        Repeater {
            model: root.service.notifications

            delegate: Item {
                id: popupDelegate

                required property var modelData
                property bool active: false

                width: popupColumn.width
                height: active ? popupCard.implicitHeight : 0
                visible: active

                Component.onCompleted: {
                    active = !modelData.lastGeneration && !root.service.dnd
                    if (active)
                        hideTimer.start()
                }

                NotificationCard {
                    id: popupCard
                    width: parent.width
                    notification: popupDelegate.modelData
                    compact: true
                }

                Timer {
                    id: hideTimer
                    interval: Math.max(
                        100,
                        popupDelegate.modelData.expireTimeout > 0
                            ? popupDelegate.modelData.expireTimeout
                            : 5000
                    )
                    repeat: false
                    onTriggered: popupDelegate.active = false
                }
            }
        }
    }
}
