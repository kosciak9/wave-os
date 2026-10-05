pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "Theme.js" as Theme

Scope {
    id: root
    required property var fallbackScreen
    property var targetScreen: fallbackScreen
    property bool opened: false
    property var bindings: []
    property string error: ""
    readonly property var filteredBindings: bindings.filter(function(binding) {
        return (binding.shortcut + " " + binding.action + " " + binding.submap).toLowerCase().includes(search.text.toLowerCase())
    })

    function toggle(): void {
        opened = !opened
        if (!opened) return
        const monitor = Hyprland.focusedMonitor
        targetScreen = Quickshell.screens.find(function(screen) { return monitor && screen.name === monitor.name }) || fallbackScreen
        search.text = ""
        bindings = []
        error = ""
        if (!query.running) query.running = true
    }

    function shortcut(binding): string {
        const modifiers = [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"], [2, "Caps"], [16, "Mod2"], [32, "Mod3"], [128, "Mod5"]]
        const keys = modifiers.filter(function(modifier) { return (binding.modmask & modifier[0]) !== 0 }).map(function(modifier) { return modifier[1] })
        const aliases = { "mouse:272": "Mouse left", "mouse:273": "Mouse right", "slash": "/", "comma": ",", "period": ".", "minus": "-", "equal": "=" }
        keys.push(aliases[binding.key] || binding.key || "code:" + binding.keycode)
        return keys.join(" + ")
    }

    IpcHandler {
        target: "keybinds"
        function toggle(): void { root.toggle() }
    }

    Process {
        id: query
        command: ["hyprctl", "-j", "binds"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text)
                    root.bindings = data.map(function(binding) {
                        return {
                            shortcut: root.shortcut(binding),
                            action: binding.description || [binding.dispatcher, binding.arg].filter(Boolean).join(" ") || "Lua callback",
                            submap: binding.submap || ""
                        }
                    }).sort(function(left, right) { return left.shortcut.localeCompare(right.shortcut) })
                } catch (error) {
                    root.error = "Could not load shortcuts from Hyprland."
                }
            }
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 || exitStatus !== 0) root.error = "Could not load shortcuts from Hyprland."
        }
    }

    PanelWindow {
        id: window
        screen: root.targetScreen
        visible: root.opened && root.targetScreen !== null
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        anchors { top: true; right: true; bottom: true; left: true }
        onVisibleChanged: if (visible) Qt.callLater(function() { search.forceActiveFocus() })

        MouseArea { anchors.fill: parent; onClicked: root.opened = false }

        Rectangle {
            width: Math.min(900, window.width - 32)
            height: Math.min(720, window.height - 64)
            anchors.centerIn: parent
            radius: Theme.notificationRadius
            color: Theme.notificationSurface
            border.color: Theme.notificationBorder
            border.width: 1
            Keys.onEscapePressed: root.opened = false
            MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

            Column {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                Item {
                    width: parent.width
                    height: 28
                    Text {
                        text: "Keyboard shortcuts · " + root.bindings.length
                        color: Theme.fujiWhite
                        font.family: Theme.fontFamily
                        font.pixelSize: 16
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Esc / close ×"
                        color: Theme.fujiGray
                        font.family: Theme.fontFamily
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        MouseArea { anchors.fill: parent; onClicked: root.opened = false }
                    }
                }

                TextField {
                    id: search
                    width: parent.width
                    height: 40
                    placeholderText: "Search shortcuts or actions…"
                    color: Theme.fujiWhite
                    placeholderTextColor: Theme.fujiGray
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    background: Rectangle { color: Theme.notificationSurfaceRaised; radius: Theme.notificationSmallRadius }
                    Keys.onEscapePressed: root.opened = false
                }

                ListView {
                    id: list
                    width: parent.width
                    height: parent.height - 92
                    clip: true
                    spacing: 4
                    model: root.filteredBindings
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        width: list.width
                        height: Math.max(42, action.implicitHeight + 20, keys.implicitHeight + 20)
                        radius: Theme.notificationSmallRadius
                        color: Theme.notificationSurfaceRaised
                        Text {
                            id: keys
                            x: 12
                            width: parent.width * 0.43 - 24
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.shortcut
                            color: Theme.crystalBlue
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                        Text {
                            id: action
                            x: parent.width * 0.43
                            width: parent.width - x - 20
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.action + (row.modelData.submap ? " [" + row.modelData.submap + "]" : "")
                            color: Theme.fujiWhite
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: root.error !== "" || list.count === 0
                        text: root.error || (query.running ? "Loading…" : "No matching shortcuts")
                        color: Theme.fujiGray
                        font.family: Theme.fontFamily
                    }
                }
            }
        }
    }
}
