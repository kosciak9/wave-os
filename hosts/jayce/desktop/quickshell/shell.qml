pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

ShellRoot {
    id: root

    NotificationService {
        id: notifications
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

    NotificationToasts {
        targetScreen: root.primaryScreen
        service: notifications
    }

    NotificationCenter {
        targetScreen: root.primaryScreen
        service: notifications
    }

    OpenCodeToasts {
        targetScreen: root.primaryScreen
    }

    Osd {
        targetScreen: root.primaryScreen
    }
}
