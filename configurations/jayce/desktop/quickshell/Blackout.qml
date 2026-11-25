pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: root

    property real blackoutOpacity: 0

    function trigger(): void {
        fadeIn.stop()
        holdTimer.stop()
        fadeOut.stop()
        fadeIn.from = blackoutOpacity
        fadeIn.start()
    }

    IpcHandler {
        target: "blackout"

        function trigger(): void {
            root.trigger()
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.trigger()
        }
    }

    NumberAnimation {
        id: fadeIn
        target: root
        property: "blackoutOpacity"
        to: 1
        duration: 10
        onFinished: holdTimer.start()
    }

    Timer {
        id: holdTimer
        interval: 550
        repeat: false
        onTriggered: {
            fadeOut.from = root.blackoutOpacity
            fadeOut.start()
        }
    }

    NumberAnimation {
        id: fadeOut
        target: root
        property: "blackoutOpacity"
        to: 0
        duration: 200
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            PanelWindow {
                id: overlay

                required property var modelData

                screen: modelData
                visible: root.blackoutOpacity > 0
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                focusable: false
                // An empty mask leaves the overlay visible but outside the
                // compositor's input region, so it cannot intercept clicks.
                mask: Region {}
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

                anchors {
                    top: true
                    right: true
                    bottom: true
                    left: true
                }

                Rectangle {
                    anchors.fill: parent
                    color: "#16161D"
                    opacity: root.blackoutOpacity

                    Image {
                        anchors.centerIn: parent
                        width: 112
                        height: 112
                        source: Quickshell.shellDir + "/assets/kanagawa.svg"
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }
                }
            }
        }
    }
}
