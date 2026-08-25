pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "Theme.js" as Theme

Scope {
    id: root
    required property var service
    required property var targetScreen
    property var groups: []
    property var expanded: ({})
    property bool rebuilding: false

    Component.onCompleted: rebuild()

    function iconSource(value): string {
        const icon = String(value || "").trim()
        if (icon.indexOf("/") === 0 || /^(file|image|qrc):/i.test(icon)) return icon
        if (icon.length > 0 && icon.indexOf(":") < 0) {
            const resolved = Quickshell.iconPath(icon)
            if (resolved.indexOf("/") === 0 || /^(file|image|qrc):/i.test(resolved)) return resolved
        }
        return Quickshell.shellDir + "/assets/bell.svg"
    }

    function rebuildLater(): void {
        if (rebuilding) return
        rebuilding = true
        Qt.callLater(function() { rebuilding = false; rebuild() })
    }
    function rebuild(): void {
        const byApp = ({})
        for (let i = 0; i < service.history.count; i++) {
            const row = service.history.get(i)
            const key = String(row.appKey || "unknown")
            if (!byApp[key]) byApp[key] = { appKey: key, appName: row.appName, appIcon: row.appIcon, entries: [], newest: Number(row.timestamp) || 0 }
            byApp[key].entries.push({ entryKey: row.entryKey, notificationId: row.notificationId, appKey: row.appKey, appName: row.appName, appIcon: row.appIcon, desktopEntry: row.desktopEntry, image: row.image, summary: row.summary, body: row.body, urgency: row.urgency, timestamp: row.timestamp, unread: row.unread })
            byApp[key].newest = Math.max(byApp[key].newest, Number(row.timestamp) || 0)
        }
        const result = Object.keys(byApp).map(function(key) {
            const group = byApp[key]
            group.entries.sort(function(a, b) { return Number(b.timestamp) - Number(a.timestamp) })
            group.expanded = !!root.expanded[key]
            return group
        })
        result.sort(function(a, b) { return b.newest - a.newest })
        groups = result
    }

    Connections {
        target: root.service.history
        ignoreUnknownSignals: true
        function onCountChanged() { root.rebuildLater() }
        function onDataChanged() { root.rebuildLater() }
        function onRowsInserted() { root.rebuildLater() }
        function onRowsRemoved() { root.rebuildLater() }
        function onModelReset() { root.rebuildLater() }
    }
    Connections { target: root.service; function onCenterOpenChanged() { if (root.service.centerOpen) root.rebuildLater() } }

    PanelWindow {
        id: window
        screen: root.targetScreen
        visible: root.targetScreen !== null && root.service.centerOpen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        anchors { top: true; right: true; bottom: true; left: true }
        mask: Region { item: root.service.centerOpen ? outside : null }
        onVisibleChanged: if (visible) Qt.callLater(function() { panel.forceActiveFocus() })

        MouseArea { id: outside; anchors.fill: parent; onClicked: root.service.close() }

        Rectangle {
            id: panel
            width: Math.max(280, Math.min(Theme.notificationPanelWidth, window.width - 24))
            height: Math.min(680, Math.max(220, window.height - 80))
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.notificationBarHeight + 12
            radius: 10; color: Theme.notificationSurface; border.width: 1; border.color: Theme.notificationBorder
            focus: true
            Keys.onEscapePressed: root.service.close()
            MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

            Column {
                id: panelContent
                anchors.fill: parent; anchors.margins: 12; spacing: 10
                Row {
                    width: parent.width; height: 28; spacing: 8
                    Text { text: "Notifications"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 14; font.weight: Font.Bold; verticalAlignment: Text.AlignVCenter }
                    Text { text: "(" + root.service.history.count + ")"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11; verticalAlignment: Text.AlignVCenter }
                    Item { width: parent.width - 250; height: 1 }
                    Text { text: "Clear"; color: Theme.crystalBlue; font.family: Theme.fontFamily; font.pixelSize: 10; MouseArea { anchors.fill: parent; onClicked: root.service.clear() } }
                    Text { text: "×"; color: Theme.fujiGray; font.pixelSize: 17; MouseArea { anchors.fill: parent; onClicked: root.service.close() } }
                }
                Row {
                    width: parent.width; height: 25; spacing: 5
                    Repeater {
                        model: [root.service.allMode, root.service.criticalMode, root.service.noneMode]
                        delegate: Rectangle {
                            required property string modelData
                            width: modeText.implicitWidth + 14; height: 24; radius: 4
                            color: root.service.mode === modelData ? Theme.waveBlue1 : Theme.sumiInk1
                            border.width: 1; border.color: root.service.mode === modelData ? Theme.crystalBlue : Theme.notificationBorder
                            Text { id: modeText; anchors.centerIn: parent; text: modelData === root.service.allMode ? "All" : modelData === root.service.criticalMode ? "Critical only" : "None"; color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 9 }
                            MouseArea { anchors.fill: parent; onClicked: root.service.setMode(modelData) }
                        }
                    }
                }
                Flickable {
                    id: flick
                    width: parent.width; height: Math.max(80, parent.height - 88)
                    clip: true; contentWidth: width; contentHeight: list.implicitHeight
                    Column { id: list; width: parent.width; spacing: 10
                        visible: root.groups.length > 0
                        Repeater {
                            model: root.groups
                            delegate: Column {
                                required property var modelData
                                width: list.width; spacing: 5
                                Row {
                                    width: parent.width; height: 30; spacing: 7
                                    Image {
                                        width: 22; height: 22; anchors.verticalCenter: parent.verticalCenter
                                        source: root.iconSource(modelData.appIcon); fillMode: Image.PreserveAspectFit; smooth: true
                                        onStatusChanged: if (status === Image.Error) source = Quickshell.shellDir + "/assets/bell.svg"
                                    }
                                    Text { text: "▸"; rotation: modelData.expanded ? 90 : 0; color: Theme.fujiGray; font.pixelSize: 12; MouseArea { anchors.fill: parent; onClicked: { root.expanded[modelData.appKey] = !modelData.expanded; root.rebuild() } } }
                                    Text { text: modelData.appName || modelData.appKey; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: Font.Bold; elide: Text.ElideRight; width: parent.width - 145 }
                                    Text { text: modelData.entries.length + "  Clear"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 9; width: 105; horizontalAlignment: Text.AlignRight; MouseArea { anchors.fill: parent; onClicked: root.service.clearApp(modelData.appKey) } }
                                }
                                Repeater {
                                    model: modelData.expanded ? modelData.entries : modelData.entries.slice(0, 1)
                                    delegate: NotificationCard { required property var modelData; width: parent.width; service: root.service; entry: modelData }
                                }
                            }
                        }
                    }
                    Text { anchors.centerIn: parent; visible: root.groups.length === 0; text: "No notifications"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11 }
                }
            }
        }
    }
}
