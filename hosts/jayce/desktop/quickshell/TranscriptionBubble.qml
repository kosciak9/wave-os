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
    property real wavePhase: 0
    readonly property int pillWidth: 168
    readonly property int pillHeight: 44
    readonly property bool active: stage === "recording" || stage === "transcribing"
    readonly property color accent: stage === "recording" ? Theme.fujiWhite
        : stage === "transcribing" ? Theme.crystalBlue
        : stage === "ready" ? Theme.springGreen
        : stage === "cancelled" ? Theme.fujiGray : Theme.waveRed

    function show(nextStage: string): void {
        stage = nextStage
        idleTimer.stop()
        hideTimer.stop()
        if (!active)
            hideTimer.restart()
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

    NumberAnimation on wavePhase {
        from: 0
        to: Math.PI * 2
        duration: root.stage === "recording" ? 900 : 1400
        loops: Animation.Infinite
        running: root.active
    }

    Rectangle {
        id: bubble
        anchors.fill: parent
        anchors.margins: 4
        radius: height / 2
        color: Theme.sumiInk0
        border.width: 1
        border.color: Theme.sumiInk3

        Row {
            anchors.centerIn: parent
            height: 28
            spacing: 5
            visible: root.active

            Repeater {
                model: 12

                delegate: Rectangle {
                    required property int index
                    readonly property real pulse: (1 + Math.sin(root.wavePhase - index * 0.48)) / 2

                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: root.stage === "recording" ? 6 + 22 * pulse : 4 + 6 * pulse
                    radius: width / 2
                    color: root.accent
                    opacity: root.stage === "recording" ? 0.6 + 0.4 * pulse : 0.25 + 0.75 * pulse
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
