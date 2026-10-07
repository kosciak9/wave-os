import QtQuick
import Quickshell
import "Theme.js" as Theme

Item {
    id: root

    property real level: 0
    property bool charging: false
    property color fillColor: level < 0.15 ? Theme.waveRed : "white"
    readonly property real unit: width / 24

    implicitWidth: 18
    implicitHeight: 18

    Image {
        anchors.fill: parent
        source: Quickshell.shellDir + (root.charging ? "/assets/battery-charge.svg" : "/assets/battery.svg")
        sourceSize.width: width
        sourceSize.height: height
        fillMode: Image.PreserveAspectFit
    }

    // Fill the outline's 14x10 cavity (x 4..18, y 7..17) with a 1-unit inset.
    Rectangle {
        visible: !root.charging
        x: 5 * root.unit
        y: 8 * root.unit
        width: Math.max(root.unit, 12 * root.unit * Math.max(0, Math.min(1, root.level)))
        height: 8 * root.unit
        color: root.fillColor
    }
}
