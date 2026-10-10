pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Theme.js" as Theme

// The calendars as `wave-agenda` expands them: today's time-blocking calendar
// in 30-minute rows, with every calendar's all-day events, and the next days of
// every calendar as strips of the same blocks.
Scope {
    id: root
    required property var fallbackScreen
    property var targetScreen: fallbackScreen
    property bool opened: false
    property bool windowVisible: false
    property var days: []
    property var calendars: []
    // The assistant files every plan into this one, so it alone fills today.
    readonly property string blockingCalendar: "time-blocking"
    // Room calendars hold everyone's bookings, not my time.
    readonly property var hiddenCalendars: ["Konferencyjny - Alergeek & Lookmove", "Budka - Alergeek & Lookmove"]
    readonly property var blockingIds: calendars.filter(calendar => calendar.name === blockingCalendar)
        .map(calendar => calendar.id)
    property bool loading: false
    property string error: ""
    readonly property int dayCount: 15
    readonly property int slotMinutes: 30
    readonly property string todayDate: Qt.formatDate(clock.date, "yyyy-MM-dd")
    readonly property int nowMinute: clock.date.getHours() * 60 + clock.date.getMinutes()
    readonly property var today: days.length > 0 && days[0].date === todayDate ? days[0] : null
    readonly property var upcoming: days.filter(day => day.date > todayDate)
    readonly property var todayBlocks: today === null ? []
        : layout(timed(today).filter(block => blockingIds.includes(block.event.calendar)))
    // 08–20 unless the range holds timed events outside it; an event running on
    // from the previous night does not pull the start to midnight.
    readonly property int rangeStart: days.reduce((first, day) => timed(day).filter(block => !block.continued)
        .reduce((earliest, block) => Math.min(earliest, Math.floor(block.start / 60) * 60), first), 8 * 60)
    readonly property int rangeEnd: days.reduce((last, day) => timed(day)
        .reduce((latest, block) => Math.max(latest, Math.ceil(block.end / 60) * 60), last), 20 * 60)
    readonly property int slotCount: (rangeEnd - rangeStart) / slotMinutes
    readonly property var nextBlock: todayBlocks.filter(block => block.event.busy && block.start > nowMinute)
        .sort((left, right) => left.start - right.start)[0] || null

    function toggle(): void {
        opened = !opened
        if (!opened) return
        const monitor = Hyprland.focusedMonitor
        targetScreen = Quickshell.screens.find(screen => monitor && screen.name === monitor.name) || fallbackScreen
        refresh()
    }

    function refresh(): void {
        if (query.running) return
        loading = true
        query.running = true
    }

    // Minutes since the day's midnight, clipped to it for events crossing it.
    function minuteOf(iso: string, date: string): int {
        const day = iso.slice(0, 10)
        if (day < date) return 0
        if (day > date) return 24 * 60
        return Number(iso.slice(11, 13)) * 60 + Number(iso.slice(14, 16))
    }

    function timed(day): var {
        return day.events.filter(event => !event.allDay).map(event => {
            const start = minuteOf(event.start, day.date)
            return {
                event: event,
                start: start,
                end: Math.max(minuteOf(event.end, day.date), start + 15),
                continued: event.start.slice(0, 10) < day.date
            }
        })
    }

    // One entry per occurrence, as a meeting shows in every calendar invited.
    function unique(events: var): var {
        const seen = new Set()
        return events.filter(event => {
            const key = event.uid + "|" + event.recurrenceId
            if (seen.has(key)) return false
            seen.add(key)
            return true
        })
    }

    function allDay(day): var {
        return day === null ? [] : day.events.filter(event => event.allDay)
    }

    // Side-by-side lanes for overlapping blocks, as many as their cluster needs.
    function layout(blocks: var): var {
        const sorted = blocks.slice().sort((left, right) => left.start - right.start || right.end - left.end)
        let cluster = []
        let lanes = []
        let clusterEnd = -1
        const flush = () => {
            for (const block of cluster) block.lanes = lanes.length
            cluster = []
            lanes = []
        }
        for (const block of sorted) {
            if (block.start >= clusterEnd) flush()
            let lane = lanes.findIndex(end => end <= block.start)
            if (lane < 0) {
                lane = lanes.length
                lanes.push(block.end)
            } else {
                lanes[lane] = block.end
            }
            block.lane = lane
            cluster.push(block)
            clusterEnd = Math.max(clusterEnd, block.end)
        }
        flush()
        return sorted
    }

    function clockText(minute: int): string {
        const hours = Math.floor(minute / 60) % 24
        return (hours < 10 ? "0" : "") + hours + ":" + (minute % 60 < 10 ? "0" : "") + minute % 60
    }

    function span(block): string {
        return clockText(block.start) + "–" + clockText(block.end)
    }

    function dayLabel(date: string, format: string): string {
        return Qt.formatDate(new Date(date + "T12:00:00"), format)
    }

    // The slot's state on a strip: 2 busy, 1 a free (tentative) block, 0 open.
    function slotState(blocks: var, slot: int): int {
        const from = rangeStart + slot * slotMinutes
        const to = from + slotMinutes
        let state = 0
        for (const block of blocks) {
            if (block.start < to && block.end > from)
                state = Math.max(state, block.event.busy ? 2 : 1)
        }
        return state
    }

    function busyMinutes(blocks: var): int {
        let total = 0
        let reach = 0
        const sorted = blocks.filter(block => block.event.busy).sort((left, right) => left.start - right.start)
        for (const block of sorted) {
            const from = Math.max(block.start, reach)
            if (block.end > from) total += block.end - from
            reach = Math.max(reach, block.end)
        }
        return total
    }

    function duration(minutes: int): string {
        const hours = Math.floor(minutes / 60)
        return hours > 0 ? hours + "h" + (minutes % 60 > 0 ? minutes % 60 : "") : minutes + "m"
    }

    onTodayDateChanged: if (windowVisible) refresh()

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
        target: "agenda"
        function toggle(): void { root.toggle() }
    }

    Process {
        id: query
        command: ["wave-agenda", "--days", String(root.dayCount)]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const agenda = JSON.parse(text)
                    const hidden = agenda.calendars.filter(calendar => root.hiddenCalendars.includes(calendar.name))
                        .map(calendar => calendar.id)
                    root.calendars = agenda.calendars.filter(calendar => !hidden.includes(calendar.id))
                    root.days = agenda.days.map(day => ({
                        date: day.date,
                        events: day.events.filter(event => !hidden.includes(event.calendar))
                    }))
                    root.error = ""
                } catch (error) {
                    root.error = "Could not read the agenda."
                }
            }
        }
        stderr: StdioCollector { id: queryError }
        onExited: function(exitCode, exitStatus) {
            root.loading = false
            if (exitCode !== 0 || exitStatus !== 0)
                root.error = queryError.text.trim().split("\n").pop() || "wave-agenda failed."
        }
    }

    // The store only moves on a sync, so an open panel rereads it now and then.
    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.windowVisible
        onTriggered: root.refresh()
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

    component Rule: Item {
        id: rule
        property string title
        property string detail
        width: parent ? parent.width : 0
        height: 16
        Label {
            id: ruleTitle
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: "── " + rule.title
            color: Theme.oldWhite; font.pixelSize: 10; font.weight: Font.DemiBold
        }
        Rectangle {
            anchors.left: ruleTitle.right; anchors.leftMargin: 6
            anchors.right: ruleDetail.left; anchors.rightMargin: ruleDetail.text.length > 0 ? 6 : 0
            anchors.verticalCenter: parent.verticalCenter
            height: 1; color: Theme.sumiInk3
        }
        Label {
            id: ruleDetail
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: rule.detail; color: Theme.fujiGray; font.pixelSize: 10
        }
    }

    component AllDayChip: Rectangle {
        id: chip
        required property var modelData
        width: Math.min(chipText.implicitWidth + 14, parent ? parent.width : 0)
        height: 18
        radius: 3
        color: "transparent"
        border.width: 1
        border.color: Theme.sumiInk3
        Label {
            id: chipText
            anchors.fill: parent; anchors.leftMargin: 7; anchors.rightMargin: 7
            verticalAlignment: Text.AlignVCenter
            text: chip.modelData.summary || "(no title)"
            color: Theme.oldWhite; font.pixelSize: 10
        }
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
            width: Math.min(Theme.agendaWidth, window.width - 24)
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
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_R) {
                    root.refresh()
                    event.accepted = true
                }
            }
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

            Item {
                id: content
                anchors.fill: parent
                anchors.margins: 16
                readonly property int gutter: 52

                Item {
                    id: header
                    width: parent.width
                    height: 40
                    Column {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Label {
                            text: "agenda"
                            font.pixelSize: 18; font.weight: Font.Bold
                        }
                        Label {
                            text: Qt.formatDate(clock.date, "dddd, d MMMM") + " · " + Qt.formatTime(clock.date, "HH:mm")
                            color: Theme.oldWhite; font.pixelSize: 10
                        }
                    }
                    Label {
                        anchors.right: parent.right; anchors.top: parent.top
                        text: root.loading ? "…" : "r ⟳  esc ×"
                        color: Theme.fujiGray; font.pixelSize: 10
                    }
                }

                Column {
                    id: todayHeader
                    anchors.top: header.bottom; anchors.topMargin: 14
                    width: parent.width
                    spacing: 8

                    Rule {
                        title: "today"
                        detail: root.today === null ? ""
                            : root.busyMinutes(root.todayBlocks) === 0 ? "free"
                            : root.duration(root.busyMinutes(root.todayBlocks)) + " blocked"
                                + (root.nextBlock !== null ? " · next " + root.clockText(root.nextBlock.start) : "")
                    }

                    Flow {
                        width: parent.width
                        spacing: 4
                        visible: root.allDay(root.today).length > 0
                        Repeater {
                            model: root.unique(root.allDay(root.today))
                            delegate: AllDayChip {}
                        }
                    }

                    Label {
                        width: parent.width
                        visible: root.error.length > 0 || (root.today === null && !root.loading)
                        text: root.error.length > 0 ? "! " + root.error : "no agenda yet"
                        color: root.error.length > 0 ? Theme.waveRed : Theme.fujiGray
                        wrapMode: Text.Wrap; maximumLineCount: 3
                    }
                }

                Flickable {
                    id: todayView
                    anchors.top: todayHeader.bottom; anchors.topMargin: 6
                    anchors.bottom: upcomingView.visible ? upcomingView.top : parent.bottom
                    anchors.bottomMargin: upcomingView.visible ? 14 : 0
                    width: parent.width
                    contentWidth: width
                    contentHeight: grid.height
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    // Rows stretch to fill the panel and scroll once they would drop under 22px.
                    readonly property real topPadding: 8
                    readonly property real rowHeight: Math.max(22, (height - topPadding) / Math.max(1, root.slotCount))
                    readonly property real nowY: topPadding + (root.nowMinute - root.rangeStart) / root.slotMinutes * rowHeight

                    function scrollToNow(): void {
                        contentY = Math.max(0, Math.min(nowY - height / 3, contentHeight - height))
                    }
                    Connections {
                        target: root
                        function onOpenedChanged() { if (root.opened) Qt.callLater(todayView.scrollToNow) }
                    }

                    Item {
                        id: grid
                        width: todayView.width
                        height: todayView.topPadding + root.slotCount * todayView.rowHeight

                        Repeater {
                            model: root.slotCount
                            delegate: Item {
                                id: slot
                                required property int index
                                readonly property int minute: root.rangeStart + index * root.slotMinutes
                                readonly property bool past: minute + root.slotMinutes <= root.nowMinute
                                width: grid.width
                                height: todayView.rowHeight
                                y: todayView.topPadding + index * height
                                opacity: past ? 0.45 : 1
                                Label {
                                    width: content.gutter - 10
                                    horizontalAlignment: Text.AlignRight
                                    anchors.top: parent.top; anchors.topMargin: -6
                                    text: slot.minute % 60 === 0 ? root.clockText(slot.minute) : "·"
                                    color: slot.minute % 60 === 0 ? Theme.fujiGray : Theme.sumiInk3
                                    font.pixelSize: 10
                                }
                                Rectangle {
                                    x: content.gutter; width: parent.width - content.gutter
                                    height: 1
                                    color: slot.minute % 60 === 0 ? Theme.sumiInk3 : Theme.sumiInk2
                                }
                            }
                        }

                        Repeater {
                            model: root.todayBlocks
                            delegate: Rectangle {
                                id: block
                                required property var modelData
                                readonly property var event: modelData.event
                                readonly property bool current: modelData.start <= root.nowMinute && modelData.end > root.nowMinute
                                readonly property bool past: modelData.end <= root.nowMinute
                                readonly property int shownStart: Math.max(modelData.start, root.rangeStart)
                                readonly property real laneWidth: (grid.width - content.gutter) / modelData.lanes
                                readonly property color accent: current ? Theme.waveRed : event.busy ? Theme.crystalBlue : Theme.fujiGray
                                x: content.gutter + modelData.lane * laneWidth + 2
                                y: todayView.topPadding + (shownStart - root.rangeStart) / root.slotMinutes * todayView.rowHeight + 2
                                width: laneWidth - 4
                                height: Math.max(12, (modelData.end - shownStart) / root.slotMinutes * todayView.rowHeight - 3)
                                radius: 3
                                color: event.busy ? (current ? Theme.waveRedTint : Theme.waveBlue1) : "transparent"
                                border.width: event.busy ? 0 : 1
                                border.color: Theme.sumiInk3
                                opacity: past ? 0.5 : 1
                                clip: true
                                Rectangle {
                                    width: 3; height: parent.height
                                    color: block.accent
                                }
                                Column {
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    anchors.right: parent.right; anchors.rightMargin: 6
                                    anchors.top: block.height > 30 ? parent.top : undefined
                                    anchors.topMargin: 4
                                    anchors.verticalCenter: block.height > 30 ? undefined : parent.verticalCenter
                                    spacing: 1
                                    Label {
                                        width: parent.width
                                        text: (block.event.summary || "(no title)")
                                            + (block.height > 30 ? "" : "  " + root.span(block.modelData))
                                        color: block.current ? Theme.waveRed : Theme.fujiWhite
                                        font.pixelSize: 11
                                    }
                                    Label {
                                        width: parent.width
                                        visible: block.height > 30
                                        text: root.span(block.modelData) + (block.event.location ? " · " + block.event.location : "")
                                        color: Theme.fujiGray; font.pixelSize: 10
                                    }
                                }
                            }
                        }

                        // Now: a line across the grid, its time in the gutter.
                        Item {
                            visible: root.today !== null && root.nowMinute >= root.rangeStart && root.nowMinute < root.rangeEnd
                            y: todayView.nowY
                            width: grid.width
                            Rectangle {
                                x: content.gutter; width: parent.width - content.gutter
                                height: 1; color: Theme.waveRed
                            }
                            Rectangle {
                                x: content.gutter - 3; y: -3
                                width: 7; height: 7; radius: 3.5
                                color: Theme.waveRed
                            }
                            Rectangle {
                                width: content.gutter - 10; height: 14; y: -7
                                color: Theme.notificationSurface
                                Label {
                                    anchors.fill: parent
                                    horizontalAlignment: Text.AlignRight; verticalAlignment: Text.AlignVCenter
                                    text: root.clockText(root.nowMinute)
                                    color: Theme.waveRed; font.pixelSize: 10; font.weight: Font.DemiBold
                                }
                            }
                        }
                    }
                }

                Column {
                    id: upcomingView
                    anchors.bottom: parent.bottom
                    width: parent.width
                    spacing: 8
                    visible: root.upcoming.length > 0
                    readonly property real stripWidth: width - content.gutter

                    Rule { title: "next days" }

                    // Hour marks over the strips, every two hours.
                    Item {
                        width: parent.width
                        height: 12
                        Repeater {
                            model: Math.floor((root.rangeEnd - root.rangeStart) / 120) + 1
                            delegate: Label {
                                required property int index
                                x: content.gutter + index * 120 / (root.rangeEnd - root.rangeStart) * upcomingView.stripWidth
                                    - (index === 0 ? 0 : implicitWidth / 2)
                                text: String(Math.floor(root.rangeStart / 60) + index * 2).padStart(2, "0")
                                color: Theme.fujiGray; font.pixelSize: 9
                                visible: x + implicitWidth <= content.width
                            }
                        }
                    }

                    Repeater {
                        model: root.upcoming
                        delegate: Item {
                            id: dayRow
                            required property var modelData
                            readonly property var blocks: root.timed(modelData)
                            readonly property var allDayEvents: root.allDay(modelData)
                            readonly property var weekend: [0, 6].includes(new Date(modelData.date + "T12:00:00").getDay())
                            width: upcomingView.width
                            height: 14

                            Label {
                                width: content.gutter - 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.dayLabel(dayRow.modelData.date, "ddd d")
                                color: dayRow.weekend ? Theme.fujiGray : Theme.oldWhite
                                font.pixelSize: 10
                            }

                            Row {
                                x: content.gutter
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Repeater {
                                    model: root.slotCount
                                    delegate: Rectangle {
                                        required property int index
                                        readonly property int level: root.slotState(dayRow.blocks, index)
                                        width: (upcomingView.stripWidth - root.slotCount) / root.slotCount
                                        height: 10
                                        radius: 1.5
                                        color: level === 2 ? Theme.crystalBlue : level === 1 ? Theme.waveBlue2 : Theme.sumiInk2
                                        opacity: level === 0 && (root.rangeStart / 30 + index) % 2 === 1 ? 0.7 : 1
                                    }
                                }
                            }

                            // All-day events tint the label's day with a marker.
                            Rectangle {
                                visible: dayRow.allDayEvents.length > 0
                                x: content.gutter - 7; anchors.verticalCenter: parent.verticalCenter
                                width: 3; height: 10; radius: 1.5
                                color: Theme.carpYellow
                            }

                            MouseArea {
                                id: dayPointer
                                anchors.fill: parent
                                hoverEnabled: true
                            }

                            Rectangle {
                                visible: dayPointer.containsMouse && (dayRow.blocks.length > 0 || dayRow.allDayEvents.length > 0)
                                z: 10
                                x: content.gutter
                                y: -height - 4
                                width: upcomingView.stripWidth
                                height: dayList.implicitHeight + 12
                                radius: 5
                                color: Theme.notificationSurfaceRaised
                                border.width: 1; border.color: Theme.notificationBorder
                                Column {
                                    id: dayList
                                    anchors.fill: parent; anchors.margins: 6
                                    spacing: 2
                                    Repeater {
                                        model: root.unique(dayRow.allDayEvents)
                                        delegate: Label {
                                            required property var modelData
                                            width: dayList.width
                                            text: "▪ " + (modelData.summary || "(no title)")
                                            color: Theme.carpYellow; font.pixelSize: 10
                                        }
                                    }
                                    Repeater {
                                        model: root.unique(dayRow.blocks.map(block => block.event))
                                            .map(event => dayRow.blocks.find(block => block.event === event))
                                            .sort((left, right) => left.start - right.start)
                                        delegate: Label {
                                            required property var modelData
                                            width: dayList.width
                                            text: root.span(modelData) + "  " + (modelData.event.summary || "(no title)")
                                            color: modelData.event.busy ? Theme.fujiWhite : Theme.fujiGray
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
