pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    NotificationService {
        id: notifications
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
    }

    TranscriptionBubble {
        targetScreen: root.primaryScreen
        notificationService: notifications
    }

    Osd {
        targetScreen: root.primaryScreen
    }
}
