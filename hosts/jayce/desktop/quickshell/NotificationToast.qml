pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "Theme.js" as Theme

Rectangle {
    id: root
    required property var service
    required property string entryKey
    required property string appName
    required property string appIcon
    required property string summary
    required property int urgency
    property string desktopEntry: ""
    property bool critical: urgency >= 2
    function localSource(value): string {
        const source = String(value || "").trim()
        return source.indexOf("/") === 0 || /^(file|image|qrc):/i.test(source) ? source : ""
    }
    function iconSource(): string {
        const value = appIcon.trim()
        const direct = localSource(value)
        if (direct.length > 0) return direct
        if (value.length > 0 && value.indexOf(":") < 0) {
            const resolved = localSource(Quickshell.iconPath(value))
            if (resolved.length > 0) return resolved
        }
        return localSource(Quickshell.shellDir + "/assets/bell.svg")
    }

    width: Theme.notificationToastWidth
    implicitHeight: 58
    radius: 6
    color: pointer.containsMouse ? Theme.sumiInk2 : Theme.sumiInk1
    border.width: 1
    border.color: critical ? "#80635A" : Theme.notificationBorder

    Row {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 9
        Image {
            width: 24; height: 24; anchors.verticalCenter: parent.verticalCenter
            source: root.iconSource(); fillMode: Image.PreserveAspectFit; smooth: true
            onStatusChanged: if (status === Image.Error) source = Quickshell.shellDir + "/assets/bell.svg"
        }
        Column {
            width: parent.width - 24 - 9 - 24 - 9
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text { width: parent.width; text: root.appName || "Notification"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight }
            Text { width: parent.width; text: (root.critical ? "! " : "") + root.summary; color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 11; textFormat: Text.PlainText; elide: Text.ElideRight; maximumLineCount: 1 }
        }
        Text { text: "×"; width: 24; height: 24; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: Theme.fujiGray; font.pixelSize: 16 }
    }
    MouseArea {
        id: pointer; anchors.fill: parent; hoverEnabled: true
        onClicked: function(mouse) {
            if (mouse.x >= width - 36) root.service.dismissEntry(root.entryKey)
            else if (!root.service.invokeDefault(root.entryKey)) root.service.open()
        }
    }
    Timer {
        interval: 5000; running: true; repeat: false
        onTriggered: if (!pointer.containsMouse) root.service.hideToast(root.entryKey); else restart()
    }
}
