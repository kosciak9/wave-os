import QtQuick
import "Theme.js" as Theme

Rectangle {
    id: root

    default property alias content: contentRow.data
    property int horizontalPadding: 8
    property int verticalPadding: 2
    property alias spacing: contentRow.spacing
    property bool active: false
    property color activeColor: Theme.sumiInk3
    property real inactiveOpacity: 1

    signal clicked(var mouse)
    signal scrolled(var wheel)

    implicitWidth: contentRow.implicitWidth + horizontalPadding * 2
    implicitHeight: Math.max(32, contentRow.implicitHeight + verticalPadding * 2)
    radius: 3
    color: active ? activeColor : pointer.containsMouse ? Theme.sumiInk2 : "transparent"
    opacity: inactiveOpacity * (pointer.pressed ? 0.82 : 1)

    Behavior on color {
        ColorAnimation { duration: Theme.normalDuration }
    }

    Behavior on implicitWidth {
        NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic }
    }

    Behavior on opacity {
        NumberAnimation { duration: Theme.fastDuration }
    }

    Behavior on scale {
        NumberAnimation { duration: Theme.fastDuration; easing.type: Easing.OutCubic }
    }

    Row {
        id: contentRow
        anchors.centerIn: parent
    }

    MouseArea {
        id: pointer
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        hoverEnabled: true
        onClicked: function(mouse) { root.clicked(mouse) }
        onWheel: function(wheel) { root.scrolled(wheel) }
    }

    scale: pointer.pressed ? 0.96 : pointer.containsMouse ? 1.02 : 1
}
