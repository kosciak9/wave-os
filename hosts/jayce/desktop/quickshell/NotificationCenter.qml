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
    property bool windowVisible: false
    property bool panelShown: false

    Component.onCompleted: {
        rebuild()
        if (service.centerOpen) {
            windowVisible = true
            panelShown = true
        }
    }

    function iconSource(value): string {
        const icon = String(value || "").trim()
        if (icon.indexOf("/") === 0 || /^(file|image|qrc):/i.test(icon)) return icon
        if (icon.length > 0 && icon.indexOf(":") < 0) {
            const resolved = Quickshell.iconPath(icon)
            if (resolved.indexOf("/") === 0 || /^(file|image|qrc):/i.test(resolved)) return resolved
        }
        return Quickshell.shellDir + "/assets/bell.svg"
    }

    function displayAppName(value): string {
        const name = String(value || "Unknown")
        const parts = name.split(".")
        return parts.length > 1 && parts[parts.length - 1].length > 0 ? parts[parts.length - 1] : name
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
    Connections {
        target: root.service
        function onCenterOpenChanged() {
            if (root.service.centerOpen) {
                root.windowVisible = true
                root.rebuildLater()
                root.panelShown = true
                hideTimer.stop()
            } else {
                root.panelShown = false
                hideTimer.restart()
            }
        }
    }

    Timer {
        id: hideTimer
        interval: Theme.slowDuration + 30
        repeat: false
        onTriggered: if (!root.service.centerOpen) root.windowVisible = false
    }

    PanelWindow {
        id: window
        screen: root.targetScreen
        visible: root.targetScreen !== null && root.windowVisible
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        anchors { top: true; right: true; bottom: true; left: true }
        mask: Region { item: root.windowVisible ? outside : null }
        onVisibleChanged: if (visible) Qt.callLater(function() { panel.forceActiveFocus() })

        MouseArea { id: outside; anchors.fill: parent; onClicked: root.service.close() }

        Rectangle {
            id: panel
            width: Math.max(280, Math.min(Theme.notificationPanelWidth, window.width - 24))
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            property real panelOffset: -8
            anchors.topMargin: Theme.notificationBarHeight + 12 + panelOffset
            readonly property real minimumHeight: 120
            readonly property real maximumHeight: Math.max(minimumHeight, window.height - anchors.topMargin - 24)
            readonly property real naturalHeight: Theme.notificationPadding * 2 + header.height + selector.height + panelContent.spacing * 2 + Math.max(list.implicitHeight, root.groups.length === 0 ? 40 : 0)
            height: Math.min(maximumHeight, Math.max(minimumHeight, naturalHeight))
            opacity: 0
            scale: 0.985
            transformOrigin: Item.Top
            radius: Theme.notificationRadius; color: Theme.notificationSurface; border.width: 1; border.color: Theme.notificationBorder
            focus: true
            Keys.onEscapePressed: root.service.close()
            MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }
            Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
            states: State {
                name: "shown"
                when: root.panelShown
                PropertyChanges { panel.opacity: 1; panel.panelOffset: 0; panel.scale: 1 }
            }
            transitions: Transition {
                reversible: true
                ParallelAnimation {
                    NumberAnimation { properties: "opacity,panelOffset,scale"; duration: Theme.slowDuration; easing.type: Easing.OutCubic }
                }
            }

            Column {
                id: panelContent
                anchors.fill: parent; anchors.margins: Theme.notificationPadding; spacing: 10
                Item {
                    id: header
                    width: parent.width; height: 26
                    Row {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 7
                        Text { text: "Notifications"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: Font.DemiBold; verticalAlignment: Text.AlignVCenter }
                        Rectangle { visible: root.service.history.count > 0; width: 5; height: 5; radius: 2.5; color: Theme.crystalBlue; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Row { id: rightControls; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                        Item { id: clearAll; visible: root.service.history.count > 0; width: 24; height: 24
                            Image { anchors.centerIn: parent; width: 13; height: 13; source: Quickshell.shellDir + "/assets/trash.svg"; fillMode: Image.PreserveAspectFit; opacity: clearAllPointer.containsMouse ? 1 : 0.8 }
                            MouseArea { id: clearAllPointer; anchors.fill: parent; hoverEnabled: true; onClicked: root.service.clear() }
                        }
                        Item { width: 24; height: 24
                            Image { anchors.centerIn: parent; width: 13; height: 13; source: Quickshell.shellDir + "/assets/xmark.svg"; fillMode: Image.PreserveAspectFit; opacity: closePointer.containsMouse ? 1 : 0.8 }
                            MouseArea { id: closePointer; anchors.fill: parent; hoverEnabled: true; onClicked: root.service.close() }
                        }
                    }
                }
                Item {
                    id: selector
                    width: Math.min(270, parent.width); height: 24; anchors.horizontalCenter: parent.horizontalCenter
                    Rectangle { anchors.fill: parent; radius: Theme.notificationSmallRadius; color: Theme.sumiInk1 }
                    Repeater {
                        model: [root.service.allMode, root.service.criticalMode, root.service.noneMode]
                        delegate: Rectangle {
                            id: selectorDelegate
                             required property int index
                             required property string modelData
                             x: selectorDelegate.index * selector.width / 3 + 2; y: 2; width: selector.width / 3 - 4; height: selector.height - 4; radius: Theme.notificationSmallRadius; color: root.service.mode === selectorDelegate.modelData ? Theme.waveBlue1 : "transparent"
                             Row { anchors.centerIn: parent; spacing: 5; opacity: root.service.mode === selectorDelegate.modelData ? 1 : 0.55
                                 Image { width: 12; height: 12; anchors.verticalCenter: parent.verticalCenter; source: Quickshell.shellDir + "/assets/" + (selectorDelegate.modelData === root.service.allMode ? "bell.svg" : selectorDelegate.modelData === root.service.criticalMode ? "half-moon.svg" : "xmark.svg"); fillMode: Image.PreserveAspectFit }
                                 Text { id: modeText; text: selectorDelegate.modelData === root.service.allMode ? "All" : selectorDelegate.modelData === root.service.criticalMode ? "Critical" : "None"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11 }
                             }
                             MouseArea { anchors.fill: parent; onClicked: root.service.setMode(selectorDelegate.modelData) }
                        }
                    }
                }
                Flickable {
                    id: flick
                    width: parent.width; height: Math.max(1, panel.height - Theme.notificationPadding * 2 - header.height - selector.height - panelContent.spacing * 2)
                    clip: true; contentWidth: width; contentHeight: list.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    Column { id: list; width: flick.width; spacing: 8
                        add: Transition { NumberAnimation { properties: "opacity,height"; duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                        move: Transition { NumberAnimation { properties: "y"; duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                        visible: root.groups.length > 0
                        Repeater {
                            model: root.groups
                            delegate: Rectangle {
                                id: groupDelegate
                                required property var modelData
                                property bool expandedState: !!modelData.expanded
                                width: list.width; radius: Theme.notificationRadius; color: Theme.notificationSurfaceRaised
                                height: groupContent.implicitHeight + Theme.notificationPadding * 2
                                Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                                Column {
                                    id: groupContent
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                    anchors.margins: Theme.notificationPadding; spacing: 4
                                    Item {
                                        width: parent.width; height: 24
                                        Image {
                                            width: 16; height: 16; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                            source: root.iconSource(modelData.appIcon); fillMode: Image.PreserveAspectFit; smooth: true
                                            onStatusChanged: if (status === Image.Error) source = Quickshell.shellDir + "/assets/bell.svg"
                                        }
                                        Text {
                                            anchors.left: parent.left; anchors.leftMargin: 23; anchors.right: groupControls.left; anchors.rightMargin: 9; anchors.verticalCenter: parent.verticalCenter
                                             text: root.displayAppName(modelData.appName || modelData.appKey); color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: Font.DemiBold; elide: Text.ElideRight
                                        }
                                        Row {
                                            id: groupControls
                                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 8; z: 2
                                             Text { id: countLabel; text: String(modelData.entries.length); color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11 }
                                             Text { visible: modelData.entries.length > 1; text: groupDelegate.expandedState ? "⌄" : "›"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11 }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            z: 0
                                             onClicked: if (modelData.entries.length > 1) {
                                                 groupDelegate.expandedState = !groupDelegate.expandedState
                                                 const persisted = Object.assign({}, root.expanded)
                                                 persisted[modelData.appKey] = groupDelegate.expandedState
                                                 root.expanded = persisted
                                             }
                                        }
                                    }
                                    Repeater {
                                         model: modelData.entries
                                         delegate: Column {
                                             id: cardDelegate
                                             required property int index
                                             required property var modelData
                                             width: groupContent.width; spacing: 0
                                             readonly property bool collapsed: cardDelegate.index > 0 && !groupDelegate.expandedState
                                             height: (cardDelegate.collapsed ? 0 : card.implicitHeight + (cardDelegate.index > 0 ? 5 : 0))
                                             opacity: cardDelegate.collapsed ? 0 : 1
                                             clip: true
                                             Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                                             Behavior on opacity { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                                             Rectangle { visible: cardDelegate.index > 0; width: parent.width; height: 1; color: Theme.notificationBorder; opacity: 0.55 }
                                             NotificationCard { id: card; width: parent.width; service: root.service; entry: cardDelegate.modelData; compact: groupDelegate.modelData.entries.length > 1 && !groupDelegate.expandedState }
                                         }
                                    }
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
