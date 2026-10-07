pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import "Theme.js" as Theme

Rectangle {
    id: root
    required property var service
    required property var entry
    readonly property bool live: service.isLive(entry.entryKey)
    property bool compact: false
    property string appName: ""
    property string appIcon: ""
    property int groupCount: 1
    property bool expanded: false
    signal toggleRequested()
    property string replyText: ""
    function localSource(value): string {
        const source = String(value || "").trim()
        return source.indexOf("/") === 0 || /^(file|image|qrc):/i.test(source) ? source : ""
    }
    implicitHeight: content.implicitHeight + 12
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
            .replace(/\n\s*\n+/g, "\n")
    }
    function stamp(): string {
        const date = new Date(Number(entry.timestamp) || 0)
        const today = new Date()
        if (date.getFullYear() === today.getFullYear() && date.getMonth() === today.getMonth() && date.getDate() === today.getDate())
            return Qt.formatDateTime(date, "HH:mm")
        return Qt.formatDateTime(date, "MMM d")
    }

    HoverHandler { id: cardHover }
    MouseArea {
        anchors.fill: parent
        onClicked: root.service.invokeDefault(root.entry.entryKey)
    }

    Column {
        id: content
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.topMargin: 6; spacing: 6
        Item {
            width: parent.width; height: 20
            MouseArea {
                anchors.fill: parent
                enabled: root.groupCount > 1
                onClicked: root.toggleRequested()
            }
            RowLayout {
                anchors.fill: parent
                spacing: 6
                Image {
                    visible: root.appName.length > 0
                    Layout.preferredWidth: 14; Layout.preferredHeight: 14
                    source: root.appIcon; fillMode: Image.PreserveAspectFit; smooth: true
                    onStatusChanged: if (status === Image.Error) source = Quickshell.shellDir + "/assets/bell.svg"
                }
                Text {
                    visible: root.appName.length > 0
                    Layout.maximumWidth: root.width * 0.4
                    text: root.appName; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11; elide: Text.ElideRight
                }
                Text { visible: root.appName.length > 0; text: "·"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11 }
                Rectangle {
                    visible: Number(root.entry.urgency) >= 2
                    Layout.preferredWidth: 4; Layout.preferredHeight: 4
                    color: Theme.waveRed
                }
                Text {
                    Layout.fillWidth: true
                    text: String(root.entry.summary || ""); color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: Font.DemiBold; textFormat: Text.PlainText; elide: Text.ElideRight; maximumLineCount: 1
                }
                Text {
                    visible: cardHover.hovered
                    Layout.preferredHeight: 20; verticalAlignment: Text.AlignVCenter
                    text: root.stamp(); color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11
                }
                Text {
                    visible: root.groupCount > 1
                    Layout.preferredHeight: 20; verticalAlignment: Text.AlignVCenter
                    text: root.groupCount; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11
                }
                Image {
                    visible: root.groupCount > 1
                    Layout.preferredWidth: 12; Layout.preferredHeight: 12; Layout.leftMargin: -3
                    sourceSize.width: 12; sourceSize.height: 12
                    source: Quickshell.shellDir + (root.expanded ? "/assets/chevron-down.svg" : "/assets/chevron-right.svg"); fillMode: Image.PreserveAspectFit
                }
            }
        }
        Row {
            width: parent.width; spacing: 10
            visible: notificationImageFrame.shown || bodyText.text.length > 0
            ClippingRectangle {
                id: notificationImageFrame
                readonly property bool shown: root.imageSource().length > 0 && notificationImage.status === Image.Ready
                visible: shown
                width: shown ? 36 : 0; height: 36
                radius: width / 2
                color: "transparent"
                Image {
                    id: notificationImage
                    anchors.fill: parent
                    source: root.imageSource(); sourceSize.width: 72; sourceSize.height: 72
                    fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true
                }
            }
            Text {
                id: bodyText
                width: parent.width - (notificationImageFrame.shown ? notificationImageFrame.width + parent.spacing : 0)
                text: root.plainBody(root.entry.body)
                color: Theme.fujiWhite; opacity: 0.82
                font.family: Theme.fontFamily; font.pixelSize: 11
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                maximumLineCount: root.compact ? 2 : 4
                elide: Text.ElideRight
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
