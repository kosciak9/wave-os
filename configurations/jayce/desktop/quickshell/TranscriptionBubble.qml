pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var targetScreen
    required property var notificationService
    property string stage: "idle"
    property string daemonState: ""
    property var audioLevels: Array(12).fill(0)
    property real borderPhase: 0
    property real borderCoverage: 0.18
    property real recordingProgress: 0
    readonly property int recordingDurationMs: Number(Quickshell.env("WAVE_DICTATION_MAX_DURATION_MS"))
    readonly property real recordingRemainingMs: (1 - recordingProgress) * recordingDurationMs
    readonly property color recordingBorderColor: recordingRemainingMs <= 5000 ? Theme.waveRed
        : recordingRemainingMs <= 10000 ? Theme.carpYellow : Theme.fujiWhite
    onRecordingProgressChanged: recordingBorder.requestPaint()
    onRecordingBorderColorChanged: recordingBorder.requestPaint()
    readonly property int pillWidth: 168
    readonly property int pillHeight: 44
    readonly property bool active: stage === "recording" || stage === "transcribing"
    readonly property color accent: stage === "recording" ? Theme.fujiWhite
        : stage === "transcribing" ? Theme.crystalBlue
        : stage === "ready" ? Theme.springGreen
        : stage === "cancelled" ? Theme.fujiGray : Theme.waveRed

    function show(nextStage: string): void {
        // State-file updates and notifications can announce the same transition.
        if (stage === nextStage)
            return
        audioLevels = Array(12).fill(0)
        recordingCountdown.stop()
        stage = nextStage
        if (nextStage === "recording")
            recordingCountdown.restart()
        borderFill.stop()
        if (nextStage === "ready")
            borderFill.restart()
        else
            borderCoverage = 0.18
        idleTimer.stop()
        hideTimer.stop()
        if (!active)
            hideTimer.restart()
    }

    function updateAudioLevel(data: string): void {
        if (stage !== "recording")
            return
        const level = Number(data)
        if (!Number.isFinite(level))
            return
        audioLevels = audioLevels.slice(1).concat([Math.max(0, Math.min(1, level))])
        audioDecayTimer.restart()
    }

    function readState(): void {
        const state = stateFile.text().trim()
        if (state === "")
            return
        const changed = state !== daemonState
        daemonState = state
        if (state === "recording" || state === "transcribing") {
            if (changed && stage !== state)
                show(state)
        } else if (active && !idleTimer.running) {
            // Idle alone is not success: cancellation, silence and errors also return idle.
            idleTimer.restart()
        }
    }

    screen: targetScreen
    visible: stage !== "idle" && targetScreen !== null
    color: "transparent"
    implicitWidth: pillWidth + 8
    implicitHeight: pillHeight + 8
    exclusionMode: ExclusionMode.Ignore
    anchors.bottom: true
    margins.bottom: pillWidth / 2 - 4
    mask: Region { item: bubble }

    Connections {
        target: root.notificationService
        function onDictationNotification(summary: string, body: string): void {
            if (/(^|\s)Transcribed$/.test(summary))
                root.show("ready")
            else if (/(^|\s)Cancelled$/.test(summary))
                root.show("cancelled")
            else if (/(^|\s)(Recording Started|Push to Talk Active)$/.test(summary))
                root.show("recording")
            else if (/(^|\s)Recording Stopped$/.test(summary))
                root.show("transcribing")
        }
    }

    FileView {
        id: stateFile
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/voxtype/state"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.readState()
        onLoadFailed: {
            if (root.active)
                root.show("unavailable")
        }
    }

    // Retry discovery after daemon startup/restart, including a previously absent file.
    Timer { interval: 1000; repeat: true; running: true; onTriggered: stateFile.reload() }
    Timer {
        id: idleTimer
        interval: 1500
        onTriggered: root.show("unfinished")
    }
    Timer { id: hideTimer; interval: root.stage === "ready" ? 2400 : 1600; onTriggered: root.stage = "idle" }

    Process {
        command: ["wave-voxtype-levels"]
        running: root.stage === "recording"
        stdout: SplitParser {
            onRead: function(data) { root.updateAudioLevel(data) }
        }
    }

    Timer {
        id: audioDecayTimer
        interval: 250
        onTriggered: root.audioLevels = Array(12).fill(0)
    }

    NumberAnimation on borderPhase {
        from: 0
        to: 1
        duration: 1800
        loops: Animation.Infinite
        running: root.stage === "transcribing"
    }

    NumberAnimation {
        id: borderFill
        target: root
        property: "borderCoverage"
        from: 0.18
        to: 1
        duration: 360
        easing.type: Easing.OutCubic
    }

    NumberAnimation {
        id: recordingCountdown
        target: root
        property: "recordingProgress"
        from: 0
        to: 1
        duration: root.recordingDurationMs
    }

    Rectangle {
        id: bubble
        anchors.fill: parent
        anchors.margins: 4
        radius: height / 2
        color: Theme.sumiInk0
        border.width: 1
        border.color: Theme.sumiInk3

        Canvas {
            id: recordingBorder
            anchors.fill: parent
            visible: root.stage === "recording"
            enabled: false
            renderTarget: Canvas.FramebufferObject
            onVisibleChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                const inset = 0.75
                const r = height / 2 - inset
                const left = inset
                const right = width - inset
                const top = inset
                const bottom = height - inset
                const centerX = width / 2
                const halfLength = width + height - 4 * inset + (Math.PI - 4) * r
                const visibleLength = Math.max(0, Math.min(1, root.recordingProgress)) * halfLength

                ctx.clearRect(0, 0, width, height)
                ctx.strokeStyle = root.recordingBorderColor
                ctx.fillStyle = root.recordingBorderColor
                ctx.lineWidth = 1.5
                ctx.lineCap = "round"
                ctx.lineJoin = "round"

                if (root.recordingProgress <= 0) {
                    ctx.beginPath()
                    ctx.arc(centerX, bottom, 0.75, 0, 2 * Math.PI)
                    ctx.fill()
                    return
                }

                function strokeHalf(clockwise) {
                    ctx.beginPath()
                    ctx.moveTo(centerX, bottom)
                    if (clockwise) {
                        ctx.lineTo(right - r, bottom)
                        ctx.arc(right - r, bottom - r, r, Math.PI / 2, 0, true)
                        ctx.lineTo(right, top + r)
                        ctx.arc(right - r, top + r, r, 0, -Math.PI / 2, true)
                        ctx.lineTo(centerX, top)
                    } else {
                        ctx.lineTo(left + r, bottom)
                        ctx.arc(left + r, bottom - r, r, Math.PI / 2, Math.PI, false)
                        ctx.lineTo(left, top + r)
                        ctx.arc(left + r, top + r, r, Math.PI, 3 * Math.PI / 2, false)
                        ctx.lineTo(centerX, top)
                    }
                    ctx.setLineDash([visibleLength, halfLength])
                    ctx.stroke()
                }

                strokeHalf(true)
                strokeHalf(false)
            }
        }

        Shape {
            id: activityBorder
            anchors.fill: parent
            visible: root.stage === "transcribing" || root.stage === "ready"
            readonly property real inset: 1
            readonly property real arcRadius: height / 2 - inset
            readonly property real perimeter: 2 * (width - height) + 2 * Math.PI * arcRadius

            ShapePath {
                strokeColor: root.stage === "ready" ? Theme.springGreen : Theme.crystalBlue
                strokeWidth: 1.5
                capStyle: ShapePath.RoundCap
                fillColor: "transparent"
                strokeStyle: root.borderCoverage >= 0.999 ? ShapePath.SolidLine : ShapePath.DashLine
                dashPattern: [root.borderCoverage * activityBorder.perimeter / strokeWidth,
                    Math.max(0.001, (1 - root.borderCoverage) * activityBorder.perimeter / strokeWidth)]
                dashOffset: -root.borderPhase * activityBorder.perimeter / strokeWidth
                startX: activityBorder.width / 2
                startY: activityBorder.inset
                PathLine { x: activityBorder.width - activityBorder.height / 2; y: activityBorder.inset }
                PathArc {
                    x: activityBorder.width - activityBorder.height / 2
                    y: activityBorder.height - activityBorder.inset
                    radiusX: activityBorder.arcRadius; radiusY: activityBorder.arcRadius
                    direction: PathArc.Clockwise
                }
                PathLine { x: activityBorder.height / 2; y: activityBorder.height - activityBorder.inset }
                PathArc {
                    x: activityBorder.height / 2
                    y: activityBorder.inset
                    radiusX: activityBorder.arcRadius; radiusY: activityBorder.arcRadius
                    direction: PathArc.Clockwise
                }
                PathLine { x: activityBorder.width / 2; y: activityBorder.inset }
            }
        }

        Row {
            anchors.centerIn: parent
            height: 28
            spacing: 5
            visible: root.stage === "recording"

            Repeater {
                model: 12

                delegate: Rectangle {
                    required property int index
                    readonly property real level: root.audioLevels[index]

                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: 4 + 24 * level
                    radius: width / 2
                    color: root.accent
                    opacity: 0.4 + 0.6 * level
                    Behavior on height { NumberAnimation { duration: 70 } }
                    Behavior on opacity { NumberAnimation { duration: 70 } }
                }
            }
        }

        Shape {
            anchors.centerIn: parent
            width: 24
            height: 24
            visible: !root.active

            ShapePath {
                strokeColor: root.stage === "ready" ? root.accent : "transparent"
                strokeWidth: 2
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                fillColor: "transparent"
                startX: 5; startY: 12
                PathLine { x: 10; y: 17 }
                PathLine { x: 20; y: 7 }
            }

            ShapePath {
                strokeColor: root.stage === "cancelled" ? root.accent : "transparent"
                strokeWidth: 2
                capStyle: ShapePath.RoundCap
                fillColor: "transparent"
                startX: 6; startY: 12
                PathLine { x: 18; y: 12 }
            }

            ShapePath {
                strokeColor: ["unfinished", "unavailable"].indexOf(root.stage) >= 0 ? root.accent : "transparent"
                strokeWidth: 2
                capStyle: ShapePath.RoundCap
                fillColor: "transparent"
                startX: 7; startY: 7
                PathLine { x: 17; y: 17 }
                PathMove { x: 17; y: 7 }
                PathLine { x: 7; y: 17 }
            }
        }
    }
}
