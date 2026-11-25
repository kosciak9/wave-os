pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

// PanelWindow's concrete platform implementation is selected by Quickshell at runtime.
// qmllint disable uncreatable-type
PanelWindow {
    required property var modelData

    screen: modelData
    color: "transparent"
    implicitWidth: 1
    implicitHeight: 1
    exclusionMode: ExclusionMode.Ignore

    anchors {
        top: true
        left: true
    }

    mask: Region { item: trigger }

    MouseArea {
        id: trigger

        anchors.fill: parent
        hoverEnabled: true
        onEntered: Hyprland.dispatch("hl.plugin.scrolloverview.overview(\"toggle\")")
    }
}
