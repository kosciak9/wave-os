pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "Theme.js" as Theme

Scope {
    id: root
    required property var service
    required property var targetScreen

    PanelWindow {
        screen: root.targetScreen
        visible: root.targetScreen !== null && root.service.toasts.count > 0
        color: "transparent"
        implicitWidth: Theme.notificationToastWidth + 16
        implicitHeight: toastColumn.height + 16
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        anchors { top: true; left: true; right: true }
        margins.top: Theme.notificationBarHeight + 8
        mask: Region { item: toastColumn }

        Column {
            id: toastColumn
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            width: Theme.notificationToastWidth
            spacing: Theme.notificationToastGap
            move: Transition { NumberAnimation { properties: "y"; duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
            add: Transition { NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: Theme.normalDuration } }
            Repeater {
                model: root.service.toasts
                delegate: NotificationToast {
                    service: root.service
                }
            }
        }
    }
}
