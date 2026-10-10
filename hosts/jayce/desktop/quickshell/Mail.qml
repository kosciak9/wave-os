pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Theme.js" as Theme

// The newest inbox envelopes of each Gmail account as himalaya reads them
// from the local neverest mirror, unread ones marked. Every neverest sync
// asks for a refresh over IPC, which keeps the bar's unread badge current.
Scope {
    id: root
    required property var fallbackScreen
    property var targetScreen: fallbackScreen
    property bool opened: false
    property bool windowVisible: false
    // The accounts of hosts/jayce/pimalaya.nix, default first.
    readonly property var accounts: ["work", "personal"]
    readonly property int pageSize: 25
    property var inboxes: []
    property int queried: 0
    property bool loading: false
    // A sync that lands while the mirror is being read gets one more pass.
    property bool stale: false
    readonly property int unreadCount: inboxes.reduce((total, inbox) => total
        + inbox.envelopes.filter(envelope => unread(envelope)).length, 0)

    function toggle(): void {
        opened = !opened
        if (!opened) return
        const monitor = Hyprland.focusedMonitor
        targetScreen = Quickshell.screens.find(screen => monitor && screen.name === monitor.name) || fallbackScreen
        refresh()
    }

    function refresh(): void {
        if (loading) {
            stale = true
            return
        }
        loading = true
        stale = false
        queried = 0
        query.running = true
    }

    function finish(inbox): void {
        const next = inboxes.filter(other => other.account !== inbox.account)
        next.push(inbox)
        inboxes = next.sort((left, right) => accounts.indexOf(left.account) - accounts.indexOf(right.account))
        queried++
        if (queried < accounts.length) {
            query.running = true
            return
        }
        loading = false
        if (stale)
            refresh()
    }

    function unread(envelope): bool {
        return !envelope.flags.some(flag => flag.iana === "seen")
    }

    function sender(envelope): string {
        const from = envelope.from[0]
        return from ? from.name || from.email : ""
    }

    function when(iso: string): string {
        const date = new Date(iso)
        const now = clock.date
        if (date.toDateString() === now.toDateString()) return Qt.formatTime(date, "HH:mm")
        if (date.getFullYear() === now.getFullYear()) return Qt.formatDate(date, "d MMM")
        return Qt.formatDate(date, "d MMM yyyy")
    }

    onOpenedChanged: {
        if (opened) {
            windowVisible = true
            hideTimer.stop()
        } else {
            hideTimer.restart()
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    IpcHandler {
        target: "mail"
        function toggle(): void { root.toggle() }
        function refresh(): void { root.refresh() }
    }

    Component.onCompleted: refresh()

    Process {
        id: query
        readonly property string account: root.accounts[root.queried] || ""
        command: ["himalaya", "-a", account, "envelope", "list", "-s", String(root.pageSize), "--json"]
        stdout: StdioCollector { id: queryOutput }
        stderr: StdioCollector { id: queryError }
        onExited: function(exitCode, exitStatus) {
            const inbox = { account: query.account, envelopes: [], error: "" }
            try {
                if (exitCode !== 0 || exitStatus !== 0)
                    throw new Error(queryError.text.trim().split("\n").pop() || "himalaya failed.")
                inbox.envelopes = JSON.parse(queryOutput.text).envelopes
            } catch (error) {
                inbox.error = error.message || "Could not read the inbox."
            }
            root.finish(inbox)
        }
    }

    Timer {
        id: hideTimer
        interval: Theme.slowDuration + 30
        onTriggered: if (!root.opened) root.windowVisible = false
    }

    component Label: Text {
        color: Theme.fujiWhite
        font.family: Theme.fontFamily
        font.pixelSize: 11
        elide: Text.ElideRight
        maximumLineCount: 1
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
        onVisibleChanged: if (visible) Qt.callLater(() => panel.forceActiveFocus())

        MouseArea { anchors.fill: parent; onClicked: root.opened = false }

        Rectangle {
            id: panel
            width: Math.min(Theme.mailWidth, window.width - 24)
            anchors.top: parent.top
            anchors.topMargin: Theme.notificationBarHeight + 12
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            // The control center's entrance, nudged in from the right edge.
            property real panelOffset: -8
            anchors.right: parent.right
            anchors.rightMargin: 12 + panelOffset
            opacity: 0
            scale: 0.985
            transformOrigin: Item.Right
            radius: Theme.notificationRadius
            color: Theme.notificationSurface
            border.width: 1
            border.color: Theme.notificationBorder
            focus: true
            Keys.onEscapePressed: root.opened = false
            MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }
            states: State {
                name: "shown"
                when: root.opened
                PropertyChanges { panel.opacity: 1; panel.panelOffset: 0; panel.scale: 1 }
            }
            transitions: Transition {
                reversible: true
                NumberAnimation { properties: "opacity,panelOffset,scale"; duration: Theme.slowDuration; easing.type: Easing.OutCubic }
            }

            Flickable {
                anchors.fill: parent
                anchors.margins: 16
                contentWidth: width
                contentHeight: inboxColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Column {
                    id: inboxColumn
                    width: parent.width
                    spacing: 18

                    Label {
                        text: "mail"
                        font.pixelSize: 18; font.weight: Font.Bold
                    }

                    Repeater {
                        model: root.inboxes

                        delegate: Column {
                            id: inbox
                            required property var modelData
                            readonly property int unreadCount: modelData.envelopes.filter(envelope => root.unread(envelope)).length
                            width: inboxColumn.width
                            spacing: 2

                            Item {
                                width: parent.width; height: 20
                                Label {
                                    id: accountTitle
                                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                    text: "── " + inbox.modelData.account
                                    color: Theme.oldWhite; font.pixelSize: 10; font.weight: Font.DemiBold
                                }
                                Rectangle {
                                    anchors.left: accountTitle.right; anchors.leftMargin: 6
                                    anchors.right: unreadLabel.left; anchors.rightMargin: unreadLabel.text.length > 0 ? 6 : 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 1; color: Theme.sumiInk3
                                }
                                Label {
                                    id: unreadLabel
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    text: inbox.unreadCount > 0 ? inbox.unreadCount + " unread" : ""
                                    color: Theme.surimiOrange; font.pixelSize: 10
                                }
                            }

                            Label {
                                visible: inbox.modelData.error.length > 0
                                width: parent.width
                                text: inbox.modelData.error
                                color: Theme.waveRed; font.pixelSize: 10
                            }

                            Repeater {
                                model: inbox.modelData.envelopes

                                delegate: Item {
                                    id: envelopeRow
                                    required property var modelData
                                    readonly property bool unread: root.unread(modelData)
                                    width: inbox.width
                                    height: 40

                                    Rectangle {
                                        visible: envelopeRow.unread
                                        anchors.left: parent.left; anchors.leftMargin: 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 6; height: 6; radius: 3
                                        color: Theme.surimiOrange
                                    }
                                    Column {
                                        anchors.left: parent.left; anchors.leftMargin: 14
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        Item {
                                            width: parent.width; height: senderLabel.implicitHeight
                                            Label {
                                                id: senderLabel
                                                anchors.left: parent.left; anchors.right: dateLabel.left; anchors.rightMargin: 8
                                                text: root.sender(envelopeRow.modelData)
                                                color: envelopeRow.unread ? Theme.fujiWhite : Theme.fujiGray
                                                font.weight: envelopeRow.unread ? Font.Bold : Font.Normal
                                            }
                                            Label {
                                                id: dateLabel
                                                anchors.right: parent.right
                                                text: root.when(envelopeRow.modelData.date)
                                                color: Theme.fujiGray; font.pixelSize: 10
                                            }
                                        }
                                        Label {
                                            width: parent.width
                                            text: envelopeRow.modelData.subject || "(no subject)"
                                            color: envelopeRow.unread ? Theme.oldWhite : Theme.fujiGray
                                            font.pixelSize: 10
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
