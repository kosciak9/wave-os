pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var targetScreen
    required property var notificationService
    property string stage: "idle"
    property string daemonState: ""
    property string preview: ""
    property double recordingStarted: 0
    property int elapsed: 0
    readonly property bool active: stage === "recording" || stage === "transcribing"
    readonly property color accent: stage === "recording" ? Theme.waveRed
        : stage === "ready" ? Theme.springGreen : Theme.crystalBlue

    function show(nextStage: string, text: string): void {
        if (nextStage === "recording" && stage !== "recording") {
            recordingStarted = Date.now()
            elapsed = 0
        }
        stage = nextStage
        preview = text
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
                show(state, "")
        } else if (active && !idleTimer.running) {
            // Idle alone is not success: cancellation, silence and errors also return idle.
            idleTimer.restart()
        }
    }

    screen: targetScreen
    visible: stage !== "idle" && targetScreen !== null
    color: "transparent"
    implicitWidth: 380
    implicitHeight: 92
    exclusionMode: ExclusionMode.Ignore
    anchors.bottom: true
    margins.bottom: 24
    mask: Region { item: bubble }

    Connections {
        target: root.notificationService
        function onDictationNotification(summary: string, body: string): void {
            if (/(^|\s)Transcribed$/.test(summary))
                root.show("ready", body)
            else if (/(^|\s)Cancelled$/.test(summary))
                root.show("cancelled", "Nagranie zostało odrzucone")
            else if (/(^|\s)(Recording Started|Push to Talk Active)$/.test(summary))
                root.show("recording", "")
            else if (/(^|\s)Recording Stopped$/.test(summary))
                root.show("transcribing", "")
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
                root.show("unavailable", "Usługa dyktowania jest niedostępna")
        }
    }

    // Retry discovery after daemon startup/restart, including a previously absent file.
    Timer { interval: 1000; repeat: true; running: true; onTriggered: stateFile.reload() }
    Timer {
        interval: 250
        repeat: true
        running: root.stage === "recording"
        onTriggered: root.elapsed = Math.floor((Date.now() - root.recordingStarted) / 1000)
    }
    Timer {
        id: idleTimer
        interval: 1500
        onTriggered: root.show("unfinished", "Nie otrzymano transkrypcji")
    }
    Timer { id: hideTimer; interval: root.stage === "ready" ? 8000 : 4000; onTriggered: { root.stage = "idle"; root.preview = "" } }

    Rectangle {
        id: bubble
        anchors.fill: parent
        anchors.margins: 4
        radius: 24
        color: Theme.sumiInk0
        border.width: 1
        border.color: root.accent

        RowLayout {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 14

            Rectangle {
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                radius: 16
                color: Theme.sumiInk2

                Text {
                    anchors.centerIn: parent
                    text: root.stage === "ready" ? "✓" : root.stage === "recording" ? "●" : root.stage === "transcribing" ? "◌" : "—"
                    color: root.accent
                    font.pixelSize: 22
                    RotationAnimator on rotation {
                        from: 0; to: 360; duration: 1400
                        loops: Animation.Infinite
                        running: root.stage === "transcribing"
                    }
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: root.stage === "recording"
                        NumberAnimation { to: 0.35; duration: 650 }
                        NumberAnimation { to: 1; duration: 650 }
                    }
                    opacity: 1
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 5

                Text {
                    Layout.fillWidth: true
                    text: root.stage === "recording" ? "Nagrywanie · " + root.elapsed + " s"
                        : root.stage === "transcribing" ? "Transkrypcja…"
                        : root.stage === "ready" ? "Gotowe · tekst w schowku"
                        : root.stage === "cancelled" ? "Anulowano" : "Brak wyniku"
                    color: root.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: root.stage === "recording" ? "Super+D kończy · Ctrl+Super+D anuluje"
                        : root.stage === "transcribing" ? "Zamieniam nagranie na tekst"
                        : root.preview.replace(/\s+/g, " ")
                    textFormat: Text.PlainText
                    color: Theme.fujiWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: !root.active
            onClicked: { root.stage = "idle"; root.preview = ""; hideTimer.stop() }
        }
    }
}
