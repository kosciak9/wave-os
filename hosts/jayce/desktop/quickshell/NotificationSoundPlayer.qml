pragma ComponentBehavior: Bound

import QtMultimedia
import Quickshell

Scope {
    id: root

    readonly property string soundPath: Quickshell.env("WAVE_NOTIFICATION_SOUND") || ""
    readonly property bool available: soundPath.length > 0

    function play(): bool {
        if (!available)
            return false

        player.stop()
        player.source = soundPath.indexOf("://") >= 0 ? soundPath : "file://" + soundPath
        player.play()
        return true
    }

    MediaPlayer {
        id: player
        audioOutput: output
        onErrorOccurred: function(error, errorString) {
            if (error !== MediaPlayer.NoError)
                console.warn("notification sound unavailable:", errorString)
        }
    }

    AudioOutput {
        id: output
        volume: 0.45
    }
}
