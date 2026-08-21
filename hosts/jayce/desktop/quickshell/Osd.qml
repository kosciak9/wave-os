pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "Theme.js" as Theme

PanelWindow {
    id: root

    required property var targetScreen
    property string label: ""
    property real value: 0
    property bool muted: false
    property bool fadingOut: true
    readonly property var trackedSink: Pipewire.defaultAudioSink
    property var trackedAudio: trackedSink !== null && trackedSink.ready ? trackedSink.audio : null
    property real lastAudioVolume: 0
    property bool lastAudioMuted: false
    property bool hasAudioState: false

    PwObjectTracker {
        id: sinkTracker
        objects: [Pipewire.defaultAudioSink]
    }

    Connections {
        target: root.trackedSink
        function onReadyChanged(): void {
            if (root.trackedSink !== null && root.trackedSink.ready)
                root.seedAudioState()
        }
    }

    Connections {
        target: root.trackedAudio
        function onVolumeChanged(): void { root.scheduleAudioUpdate() }
        function onMutedChanged(): void { root.scheduleAudioUpdate() }
    }

    onTrackedSinkChanged: resetAudioState()
    onTrackedAudioChanged: resetAudioState()

    function resetAudioState() {
        hasAudioState = false
        audioUpdateTimer.stop()
        audioSeedTimer.restart()
    }

    function seedAudioState() {
        if (trackedSink === null || !trackedSink.ready || trackedAudio === null)
            return
        lastAudioVolume = trackedAudio.volume
        lastAudioMuted = trackedAudio.muted
        hasAudioState = true
    }

    function scheduleAudioUpdate() {
        if (hasAudioState)
            audioUpdateTimer.restart()
    }

    function showAudioUpdate() {
        if (trackedSink === null || !trackedSink.ready || trackedAudio === null || !hasAudioState)
            return
        const volume = trackedAudio.volume
        const mutedState = trackedAudio.muted
        const volumeChanged = volume !== lastAudioVolume
        const muteChanged = mutedState !== lastAudioMuted
        lastAudioVolume = volume
        lastAudioMuted = mutedState
        if (volumeChanged || muteChanged)
            showVolume(volume, mutedState)
    }

    function showVolume(volume, mutedState) {
        label = mutedState ? "MUTED" : "VOLUME"
        value = Math.max(0, Math.min(1, volume))
        muted = mutedState
        fadingOut = false
        visible = true
        hideTimer.restart()
    }

    function showBrightness(data) {
        const match = data.match(/([0-9]+)%/)
        if (match === null)
            return

        label = "BRIGHTNESS"
        value = Math.max(0, Math.min(1, Number(match[1]) / 100))
        muted = false
        fadingOut = false
        visible = true
        hideTimer.restart()
    }

    screen: targetScreen
    visible: false
    color: "transparent"
    implicitWidth: 320
    implicitHeight: 76
    exclusionMode: ExclusionMode.Ignore
    anchors {
        bottom: true
    }

    margins {
        bottom: 116
    }

    mask: Region { item: background }

    IpcHandler {
        target: "osd"

        function brightness(data: string): void {
            root.showBrightness(data)
        }
    }

    Timer {
        id: hideTimer
        interval: 1400
        onTriggered: root.fadingOut = true
    }

    Timer { id: audioSeedTimer; interval: 0; onTriggered: root.seedAudioState() }
    Timer { id: audioUpdateTimer; interval: 0; onTriggered: root.showAudioUpdate() }

    Rectangle {
        id: background
        anchors.fill: parent
        radius: 8
        color: Theme.sumiInk0
        opacity: root.fadingOut ? 0 : 1
        border.width: 1
        border.color: Theme.sumiInk3
        onOpacityChanged: {
            if (root.fadingOut && root.visible && opacity <= 0.01)
                root.visible = false
        }

        Behavior on opacity {
            enabled: root.fadingOut
            NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic }
        }
        transform: Translate {
            id: slideTransform
            y: root.fadingOut ? 10 : 0
            Behavior on y {
                enabled: root.fadingOut
                NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic }
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 14

            Text {
                Layout.preferredWidth: 76
                text: root.label
                color: root.muted ? Theme.waveRed : Theme.oldWhite
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.weight: Font.Bold
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: Math.round(root.value * 100) + "%"
                    color: Theme.fujiWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Bold
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 7
                    radius: 4
                    color: Theme.sumiInk3

                    Rectangle {
                        width: parent.width * root.value
                        height: parent.height
                        radius: parent.radius
                        color: root.muted ? Theme.waveRed : Theme.crystalBlue
                    }
                }
            }
        }
    }
}
