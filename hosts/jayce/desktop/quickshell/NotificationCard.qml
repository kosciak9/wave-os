pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "Theme.js" as Theme

Rectangle {
    id: root
    required property var service
    required property var entry
    readonly property bool live: service.isLive(entry.entryKey)
    property bool compact: false
    property string replyText: ""
    function localSource(value): string {
        const source = String(value || "").trim()
        return source.indexOf("/") === 0 || /^(file|image|qrc):/i.test(source) ? source : ""
    }
    implicitHeight: content.implicitHeight + 16
    radius: Theme.notificationSmallRadius
    color: "transparent"
    border.width: 0

    function imageSource(): string { return localSource(entry.image) }
    function visibleActions(): var {
        const descriptors = service.actionDescriptors(entry.entryKey)
        const actions = []
        for (let i = 0; i < descriptors.length; i++) {
            if (String(descriptors[i].identifier) !== "default")
                actions.push(descriptors[i])
        }
        return actions
    }
    function plainBody(value): string {
        return String(value || "")
            .replace(/<[^>]*>/g, "")
            .replace(/&amp;/g, "&")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/&quot;/g, '"')
            .replace(/&#39;/g, "'")
    }
    function stamp(): string {
        const date = new Date(Number(entry.timestamp) || 0)
        const today = new Date()
        if (date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth() && date.getDate() === today.getDate())
            return Qt.formatDateTime(date, "HH:mm")
        return Qt.formatDateTime(date, "MMM d")
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.service.invokeDefault(root.entry.entryKey)
    }

    Column {
        id: content
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 8; spacing: 8
        Row {
            width: parent.width; spacing: 9
            Item {
                width: parent.width - 70 - 24 - 9 * 2
                height: 24
                Row {
                    anchors.fill: parent
                    spacing: 9
                    Rectangle {
                        visible: Number(root.entry.urgency) >= 2
                        width: visible ? 4 : 0; height: 4; anchors.verticalCenter: parent.verticalCenter
                        color: Theme.waveRed
                    }
                    Text { width: parent.width - (Number(root.entry.urgency) >= 2 ? 4 + 9 : 0); anchors.verticalCenter: parent.verticalCenter; text: String(root.entry.summary || ""); color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: Font.DemiBold; textFormat: Text.PlainText; elide: Text.ElideRight; maximumLineCount: 1 }
                }
            }
            Text { width: 70; text: root.stamp(); color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight }
            Item { width: 24; height: 24
                Image { anchors.centerIn: parent; width: 12; height: 12; source: Quickshell.shellDir + "/assets/xmark.svg"; fillMode: Image.PreserveAspectFit; opacity: closePointer.containsMouse ? 1 : 0 }
                MouseArea { id: closePointer; anchors.fill: parent; hoverEnabled: true; onClicked: root.service.dismissEntry(root.entry.entryKey) }
            }
        }
        Text {
            width: parent.width
            visible: text.length > 0
            text: root.plainBody(root.entry.body)
            color: Theme.fujiWhite; opacity: 0.82
            font.family: Theme.fontFamily; font.pixelSize: 11
            textFormat: Text.PlainText; wrapMode: Text.Wrap
            maximumLineCount: root.compact ? 3 : 999999
            elide: root.compact ? Text.ElideRight : Text.ElideNone
        }
        Item {
            id: notificationImageFrame
            width: Math.min(parent.width, root.compact ? 160 : 320)
            height: root.compact ? 90 : 160
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.imageSource().length > 0 && notificationImage.status === Image.Ready
            Image {
                id: notificationImage
                anchors.fill: parent
                source: root.imageSource(); fillMode: Image.PreserveAspectFit; asynchronous: true
            }
        }
        Row {
            width: parent.width; spacing: 6; visible: root.live && actionRepeater.count > 0
            Repeater {
                id: actionRepeater
                model: root.live ? root.visibleActions() : []
                delegate: Rectangle {
                    id: actionDelegate
                    required property var modelData
                    width: actionText.implicitWidth + 16; height: 28; radius: Theme.notificationSmallRadius; color: actionPointer.containsMouse ? Theme.sumiInk3 : Theme.sumiInk1
                    Text { id: actionText; anchors.centerIn: parent; text: String(actionDelegate.modelData.text || actionDelegate.modelData.identifier || "Action"); color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 11; elide: Text.ElideRight }
                    MouseArea { id: actionPointer; anchors.fill: parent; hoverEnabled: true; onClicked: root.service.invokeAction(root.entry.entryKey, String(actionDelegate.modelData.identifier)) }
                }
            }
        }
        Row {
            width: parent.width; spacing: 6
            visible: root.live && root.service.liveNotification(root.entry.entryKey) !== null && root.service.liveNotification(root.entry.entryKey).hasInlineReply
            Rectangle { width: parent.width - 62; height: 28; color: Theme.sumiInk1; radius: Theme.notificationSmallRadius; border.width: 1; border.color: Theme.notificationBorder
                TextInput { id: replyInput; anchors.fill: parent; anchors.margins: 6; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; clip: true; onTextChanged: root.replyText = text }
            }
            Rectangle { width: 56; height: 28; radius: Theme.notificationSmallRadius; color: Theme.waveBlue2
                Text { anchors.centerIn: parent; text: "Send"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11 }
                MouseArea { anchors.fill: parent; onClicked: if (root.service.sendInlineReply(root.entry.entryKey, root.replyText)) { replyInput.text = ""; root.replyText = "" } }
            }
        }
    }
}
