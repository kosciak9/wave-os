pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
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
    property var sinkProperties: trackedSink !== null && trackedSink.ready ? trackedSink.properties : null
    property string outputKind: classifyOutput()
    property string outputName: summarizeOutput()
    readonly property var compactOutputNames: ({
        "bluetooth-headphones": "BT Headphones",
        "bluetooth-speakers": "BT Speaker",
        "display": "Display",
        "earbuds": "Earbuds",
        "headphones": "Headphones",
        "network": "Network",
        "usb": "USB Audio",
        "dock": "Dock",
        "built-in": "Speakers",
        "speakers": "Speakers",
        "generic": "Audio"
    })
    property string outputIcon: Quickshell.shellDir + "/assets/audio-" + outputKind + ".svg"
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

    // Keep this deliberately metadata-first: descriptions are often localized, while
    // the device api/bus and ALSA path are stable across Pipewire node renames.
    function metadataValue(key) {
        if (sinkProperties === null || sinkProperties[key] === undefined || sinkProperties[key] === null)
            return ""
        return String(sinkProperties[key]).toLowerCase()
    }

    function sinkText() {
        if (trackedSink === null || !trackedSink.ready)
            return ""
        return String(trackedSink.description || "") + " " + String(trackedSink.nickname || "") + " " + String(trackedSink.name || "")
    }

    function bluetoothDevice() {
        const address = metadataValue("api.bluez5.address")
        if (address === "")
            return null
        if (Bluetooth.devices === null || Bluetooth.devices.values === undefined)
            return null
        const devices = Bluetooth.devices.values
        for (let i = 0; i < devices.length; ++i) {
            if (String(devices[i].address || "").toLowerCase() === address)
                return devices[i]
        }
        return null
    }

    function classifyOutput() {
        const api = metadataValue("device.api")
        const bus = metadataValue("device.bus")
        const alsaPath = metadataValue("api.alsa.path")
        const profile = metadataValue("device.profile.name") + " " + metadataValue("device.profile.description")
        const icon = metadataValue("device.icon-name") + " " + metadataValue("application.icon-name")
        const text = sinkText().toLowerCase()
        const bt = bluetoothDevice()
        const btIcon = bt === null ? "" : String(bt.icon || "").toLowerCase()
        const btName = bt === null ? "" : String(bt.name || "").toLowerCase()
        const all = profile + " " + icon + " " + btIcon + " " + btName + " " + text

        if (api === "bluez5" || bus === "bluetooth") {
            if (all.indexOf("headset") >= 0 || all.indexOf("headphone") >= 0 || all.indexOf("earbud") >= 0 || all.indexOf("airpod") >= 0)
                return all.indexOf("earbud") >= 0 || all.indexOf("airpod") >= 0 ? "earbuds" : "bluetooth-headphones"
            return "bluetooth-speakers"
        }
        if (alsaPath.indexOf("hdmi") >= 0 || alsaPath.indexOf("displayport") >= 0 || all.indexOf("hdmi") >= 0 || all.indexOf("displayport") >= 0 || all.indexOf("monitor") >= 0)
            return "display"
        if (all.indexOf("earbud") >= 0 || all.indexOf("airpod") >= 0)
            return "earbuds"
        if (all.indexOf("headset") >= 0 || all.indexOf("headphone") >= 0)
            return "headphones"
        if (api === "network" || bus === "network" || all.indexOf("cast") >= 0 || all.indexOf("sonos") >= 0 || all.indexOf("network") >= 0)
            return "network"
        if (bus === "usb" || api === "usb" || all.indexOf("usb") >= 0)
            return "usb"
        if (all.indexOf("line out") >= 0 || all.indexOf("line-out") >= 0 || all.indexOf("dock") >= 0)
            return "dock"
        if (api === "alsa" && bus === "pci" && (alsaPath.indexOf("front") >= 0 || all.indexOf("analog") >= 0))
            return "built-in"
        if (all.indexOf("speaker") >= 0 || all.indexOf("audio") >= 0)
            return "speakers"
        return "generic"
    }

    function summarizeOutput() {
        if (trackedSink === null || !trackedSink.ready)
            return compactOutputNames.generic
        const bt = bluetoothDevice()
        const bluetoothName = bt === null ? "" : String(bt.name || "")
        if (usefulOutputName(bluetoothName) && bluetoothName.length <= 14)
            return bluetoothName
        return compactOutputNames[outputKind] || compactOutputNames.generic
    }

    function usefulOutputName(value) {
        const normalized = value.toLowerCase().trim()
        if (normalized === "" || normalized.indexOf("alsa_") === 0 || normalized.indexOf("bluez_") === 0)
            return false
        return normalized !== "usb audio" && normalized !== "hd-audio generic" && normalized !== "analog"
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

            RowLayout {
                Layout.minimumWidth: 116
                Layout.preferredWidth: 116
                Layout.maximumWidth: 116
                spacing: 7

                Image {
                    visible: root.label !== "BRIGHTNESS"
                    Layout.minimumWidth: visible ? 24 : 0
                    Layout.preferredWidth: visible ? 24 : 0
                    Layout.maximumWidth: visible ? 24 : 0
                    Layout.preferredHeight: 24
                    source: root.outputIcon
                    fillMode: Image.PreserveAspectFit
                }

                Text {
                    Layout.fillWidth: true
                    text: root.label === "BRIGHTNESS" ? root.label : root.outputName
                    color: Theme.oldWhite
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.weight: root.label === "BRIGHTNESS" ? Font.Bold : Font.Normal
                    elide: Text.ElideRight
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: root.muted ? "MUTED" : Math.round(root.value * 100) + "%"
                    color: root.muted ? Theme.waveRed : Theme.fujiWhite
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

                        Behavior on width {
                            NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic }
                        }
                    }
                }
            }
        }
    }
}
