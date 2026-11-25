pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    NotificationService {
        id: notifications
    }

    BatteryService {
        id: battery
        notificationService: notifications
    }

    Tailscale {
        id: tailscale
    }

    WaveUpdate {
        id: waveUpdate
    }

    readonly property bool t3Focused: {
        const window = ToplevelManager.activeToplevel
        const appId = window ? String(window.appId).toLowerCase() : ""
        return appId === "t3code" || appId === "com.t3tools.t3code"
    }

    onT3FocusedChanged: {
        if (!t3Focused) return
        notifications.clearApp("t3code")
        notifications.clearApp("com.t3tools.t3code")
        notifications.clearApp("t3 code (beta)")
        notifications.clearApp("t3 code")
    }

    readonly property bool slackFocused: {
        const window = ToplevelManager.activeToplevel
        const appId = window ? String(window.appId).toLowerCase() : ""
        return appId === "slack" || appId === "com.slack.slack"
    }

    onSlackFocusedChanged: {
        if (!slackFocused) return
        // Slack does not reliably withdraw notifications after messages are read.
        notifications.clearApp("slack")
        notifications.clearApp("com.slack.slack")
    }

    Caffeinate {
        id: caffeinate
    }

    LidOverride {
        id: lidOverride
    }

    WatchService {
        id: watch
    }

    Weather {
        id: weather
    }

    readonly property var primaryScreen: {
        const screens = Quickshell.screens
        let first = null
        let builtIn = null

        for (let index = 0; index < screens.length; index++) {
            const candidate = screens[index]
            const name = candidate.name || ""
            if (first === null)
                first = candidate
            if (name.startsWith("eDP") || name.startsWith("LVDS")) {
                builtIn = candidate
                break
            }
        }

        return builtIn || first
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            Bar {
                primary: modelData === root.primaryScreen
                notificationService: notifications
                batteryService: battery
                mail: mailPanel
            }
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            HotCorner {}
        }
    }

    Blackout {}

    Keybinds {
        fallbackScreen: root.primaryScreen
    }

    Agenda {
        fallbackScreen: root.primaryScreen
    }

    Mail {
        id: mailPanel
    }

    NotificationToasts {
        targetScreen: root.primaryScreen
        service: notifications
    }

    ControlCenter {
        targetScreen: Quickshell.screens.indexOf(notifications.centerScreen) >= 0 ? notifications.centerScreen : root.primaryScreen
        service: notifications
        caffeinateService: caffeinate
        lidOverrideService: lidOverride
        watchService: watch
        weatherService: weather
        batteryService: battery
        tailscaleService: tailscale
        updateService: waveUpdate
    }

    TranscriptionBubble {
        targetScreen: root.primaryScreen
        notificationService: notifications
    }

    Osd {
        targetScreen: root.primaryScreen
    }
}
