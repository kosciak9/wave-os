pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "Theme.js" as Theme

Rectangle {
    id: root
    required property var service
    required property var entry
    readonly property bool live: service.isLive(entry.entryKey)
    property string replyText: ""
    function localSource(value): string {
        const source = String(value || "").trim()
        return source.indexOf("/") === 0 || /^(file|image|qrc):/i.test(source) ? source : ""
    }
    implicitHeight: content.implicitHeight + 24
    radius: 6
    color: Theme.notificationSurfaceRaised
    border.width: 1
    border.color: entry.urgency >= 2 ? "#80635A" : Theme.notificationBorder

    function iconSource(): string {
        const value = String(entry.appIcon || "").trim()
        const direct = localSource(value)
        if (direct.length > 0) return direct
        if (value.length > 0 && value.indexOf(":") < 0) { const resolved = localSource(Quickshell.iconPath(value)); if (resolved.length > 0) return resolved }
        return localSource(Quickshell.shellDir + "/assets/bell.svg")
    }
    function imageSource(): string { return localSource(entry.image) }
    function stamp(): string {
        const date = new Date(Number(entry.timestamp) || 0)
        return Qt.formatDateTime(date, "MMM d, HH:mm")
    }

    Column {
        id: content
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 12; spacing: 8
        Row {
            width: parent.width; spacing: 9
            Image {
                width: 28; height: 28; source: root.iconSource(); fillMode: Image.PreserveAspectFit; smooth: true
                onStatusChanged: if (status === Image.Error) source = Quickshell.shellDir + "/assets/bell.svg"
            }
            Column {
                width: parent.width - 28 - 9 - 24; spacing: 1
                Text { width: parent.width; text: String(root.entry.appName || "Notification"); color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: Font.Bold; elide: Text.ElideRight }
                Text { width: parent.width; text: root.stamp() + " · " + (Number(root.entry.urgency) >= 2 ? "Critical" : Number(root.entry.urgency) <= 0 ? "Low" : "Normal"); color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight }
            }
            Text { width: 24; text: "×"; color: Theme.fujiGray; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; onClicked: root.service.dismissEntry(root.entry.entryKey) } }
        }
        Text { width: parent.width; text: String(root.entry.summary || ""); color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: Font.Bold; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
        Text { width: parent.width; visible: text.length > 0; text: String(root.entry.body || ""); color: Theme.fujiWhite; opacity: 0.82; font.family: Theme.fontFamily; font.pixelSize: 10; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 8; elide: Text.ElideRight }
        Image {
            id: notificationImage
            width: parent.width; height: 120; visible: String(root.entry.image || "").length > 0 && status === Image.Ready
            source: root.imageSource(); fillMode: Image.PreserveAspectFit; asynchronous: true
        }
        Row {
            width: parent.width; spacing: 6; visible: root.live && actionRepeater.count > 0
            Repeater {
                id: actionRepeater
                model: root.live ? root.service.actionDescriptors(root.entry.entryKey) : []
                delegate: Rectangle {
                    id: actionDelegate
                    required property var modelData
                    width: actionText.implicitWidth + 16; height: 26; radius: 4; color: actionPointer.containsMouse ? Theme.sumiInk3 : Theme.sumiInk1
                    Text { id: actionText; anchors.centerIn: parent; text: String(actionDelegate.modelData.text || actionDelegate.modelData.identifier || "Action"); color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight }
                    MouseArea { id: actionPointer; anchors.fill: parent; hoverEnabled: true; onClicked: root.service.invokeAction(root.entry.entryKey, String(actionDelegate.modelData.identifier)) }
                }
            }
        }
        Row {
            width: parent.width; spacing: 6
            visible: root.live && root.service.liveNotification(root.entry.entryKey) !== null && root.service.liveNotification(root.entry.entryKey).hasInlineReply
            Rectangle { width: parent.width - 62; height: 28; color: Theme.sumiInk1; radius: 4; border.width: 1; border.color: Theme.notificationBorder
                TextInput { id: replyInput; anchors.fill: parent; anchors.margins: 6; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 10; clip: true; onTextChanged: root.replyText = text }
            }
            Rectangle { width: 56; height: 28; radius: 4; color: Theme.waveBlue2
                Text { anchors.centerIn: parent; text: "Send"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 9 }
                MouseArea { anchors.fill: parent; onClicked: if (root.service.sendInlineReply(root.entry.entryKey, root.replyText)) { replyInput.text = ""; root.replyText = "" } }
            }
        }
    }
}
