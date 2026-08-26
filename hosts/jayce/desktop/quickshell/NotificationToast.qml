pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "Theme.js" as Theme

Rectangle {
    id: root
    required property var service
    required property string entryKey
    required property string appName
    required property string appIcon
    required property string summary
    required property int urgency
    property string desktopEntry: ""
    property bool critical: urgency >= 2
    property real lifeProgress: 0
    onLifeProgressChanged: lifeBorder.requestPaint()
    function localSource(value): string {
        const source = String(value || "").trim()
        return source.indexOf("/") === 0 || /^(file|image|qrc):/i.test(source) ? source : ""
    }
    function iconSource(): string {
        const value = appIcon.trim()
        const direct = localSource(value)
        if (direct.length > 0) return direct
        if (value.length > 0 && value.indexOf(":") < 0) {
            const resolved = localSource(Quickshell.iconPath(value))
            if (resolved.length > 0) return resolved
        }
        return localSource(Quickshell.shellDir + "/assets/bell.svg")
    }

    width: Theme.notificationToastWidth
    implicitHeight: 46
    radius: Theme.notificationRadius
    color: pointer.containsMouse ? Theme.sumiInk2 : Theme.sumiInk1

    Row {
        anchors.fill: parent
        anchors.margins: Theme.notificationPadding
        spacing: 7
        Item {
            width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
            Image {
                anchors.fill: parent
                source: root.iconSource(); fillMode: Image.PreserveAspectFit; smooth: true
                onStatusChanged: if (status === Image.Error) source = Quickshell.shellDir + "/assets/bell.svg"
            }
        }
        Rectangle {
            visible: root.critical
            width: 4; height: 4; radius: 2; anchors.verticalCenter: parent.verticalCenter
            color: Theme.waveRed
        }
        Text {
            width: parent.width - 16 - (root.critical ? 4 + 7 * 3 : 7 * 2) - 24
            anchors.verticalCenter: parent.verticalCenter
            text: root.summary
            color: Theme.oldWhite
            font.family: Theme.fontFamily
            font.pixelSize: 11
            textFormat: Text.PlainText
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Item {
            width: 24; height: 24
            Image {
                anchors.centerIn: parent
                width: 12; height: 12
                source: Quickshell.shellDir + "/assets/xmark.svg"
                fillMode: Image.PreserveAspectFit
                opacity: pointer.containsMouse ? 1 : 0
            }
        }
    }
    Canvas {
        id: lifeBorder
        anchors.fill: parent
        z: 1
        enabled: false
        renderTarget: Canvas.FramebufferObject
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            const inset = 0.5
            const r = Math.max(0, Math.min(root.radius - inset, Math.min(width, height) / 2 - inset))
            const left = inset
            const right = width - inset
            const top = inset
            const bottom = height - inset
            const centerX = width / 2
            const halfLength = width + height + (Math.PI - 4) * r
            const visibleLength = Math.max(0, Math.min(1, root.lifeProgress)) * halfLength

            ctx.clearRect(0, 0, width, height)
            ctx.strokeStyle = Theme.fujiWhite
            ctx.fillStyle = Theme.fujiWhite
            ctx.lineWidth = 1
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            if (root.lifeProgress <= 0) {
                ctx.beginPath()
                ctx.arc(centerX, bottom, 0.5, 0, 2 * Math.PI)
                ctx.fill()
                return
            }

            function strokeHalf(clockwise) {
                ctx.beginPath()
                ctx.moveTo(centerX, bottom)
                if (clockwise) {
                    ctx.lineTo(right - r, bottom)
                    ctx.arc(right - r, bottom - r, r, Math.PI / 2, 0, true)
                    ctx.lineTo(right, top + r)
                    ctx.arc(right - r, top + r, r, 0, -Math.PI / 2, true)
                    ctx.lineTo(centerX, top)
                } else {
                    ctx.lineTo(left + r, bottom)
                    ctx.arc(left + r, bottom - r, r, Math.PI / 2, Math.PI, false)
                    ctx.lineTo(left, top + r)
                    ctx.arc(left + r, top + r, r, Math.PI, 3 * Math.PI / 2, false)
                    ctx.lineTo(centerX, top)
                }
                ctx.setLineDash([visibleLength, halfLength])
                ctx.stroke()
            }

            strokeHalf(true)
            strokeHalf(false)
        }
    }
    MouseArea {
        id: pointer; anchors.fill: parent; hoverEnabled: true
        onContainsMouseChanged: {
            if (containsMouse) {
                if (lifeAnimation.running) lifeAnimation.pause()
                holdTimer.stop()
            } else if (root.lifeProgress >= 1) {
                holdTimer.restart()
            } else {
                lifeAnimation.resume()
            }
        }
        onClicked: function(mouse) {
            if (mouse.x >= width - 36) root.service.dismissEntry(root.entryKey)
            else if (!root.service.invokeDefault(root.entryKey)) root.service.open()
        }
    }
    NumberAnimation {
        id: lifeAnimation
        target: root
        property: "lifeProgress"
        from: 0
        to: 1
        duration: 4000
        running: true
        onFinished: if (!pointer.containsMouse) holdTimer.start()
    }
    Timer {
        id: holdTimer
        interval: 1000
        repeat: false
        onTriggered: root.service.hideToast(root.entryKey)
    }
}
