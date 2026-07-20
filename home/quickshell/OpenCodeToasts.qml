pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Theme.js" as Theme

Scope {
    id: root

    required property var targetScreen
    property int nextToastId: 0

    function showToast(project: string, stage: string, message: string): void {
        if (message.length === 0)
            return

        toastModel.append({
            "toastId": ++nextToastId,
            "projectName": project,
            "stageName": stage,
            "messageText": message
        })
    }

    function dismissToast(toastId: int): void {
        for (let index = 0; index < toastModel.count; index++) {
            if (toastModel.get(index).toastId === toastId) {
                toastModel.remove(index)
                return
            }
        }
    }

    ListModel {
        id: toastModel
    }

    IpcHandler {
        target: "opencode"

        function notify(project: string, stage: string, message: string): void {
            root.showToast(project, stage, message)
        }
    }

    PanelWindow {
        id: toastWindow

        screen: root.targetScreen
        visible: root.targetScreen !== null && toastModel.count > 0
        color: "transparent"
        implicitWidth: 336
        implicitHeight: toastColumn.implicitHeight + 16
        exclusionMode: ExclusionMode.Ignore

        anchors {
            bottom: true
        }

        margins {
            bottom: 205
        }

        mask: Region { item: toastColumn }

        Column {
            id: toastColumn

            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.bottom
                margins: 8
            }
            width: 320
            spacing: 8

            Repeater {
                model: toastModel

                delegate: Rectangle {
                    id: toast

                    required property int toastId
                    required property string projectName
                    required property string stageName
                    required property string messageText
                    property bool shown: false

                    function dismiss(): void {
                        if (!shown)
                            return

                        shown = false
                        removeTimer.start()
                    }

                    width: toastColumn.width
                    implicitHeight: toastContent.implicitHeight + 40
                    radius: 8
                    color: toastPointer.containsMouse ? "#352A1F" : "#1F1A14"
                    border.width: 1
                    border.color: Theme.surimiOrange
                    opacity: shown ? 1 : 0

                    Component.onCompleted: shown = true

                    Behavior on color {
                        ColorAnimation { duration: 150 }
                    }

                    Behavior on opacity {
                        NumberAnimation { duration: 100 }
                    }

                    Row {
                        id: toastContent

                        anchors {
                            top: parent.top
                            left: parent.left
                            right: parent.right
                            margins: 0
                        }
                        anchors.leftMargin: 18
                        anchors.rightMargin: 18
                        anchors.topMargin: 20
                        spacing: 16

                        Image {
                            width: 28
                            height: 28
                            source: Quickshell.shellDir + "/assets/opencode.svg"
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }

                        Column {
                            width: parent.width - 28 - parent.spacing
                            spacing: 2

                            Text {
                                width: parent.width
                                text: toast.projectName.length > 0
                                    ? toast.stageName.toUpperCase() + " — " + toast.projectName.toUpperCase()
                                    : toast.stageName.toUpperCase()
                                color: Theme.surimiOrange
                                elide: Text.ElideRight
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 1
                            }

                            Text {
                                width: parent.width
                                text: toast.messageText
                                color: Theme.fujiWhite
                                textFormat: Text.PlainText
                                wrapMode: Text.Wrap
                                maximumLineCount: 4
                                elide: Text.ElideRight
                                font.family: Theme.fontFamily
                                font.pixelSize: 13
                                font.weight: Font.Bold
                            }
                        }
                    }

                    MouseArea {
                        id: toastPointer
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: toast.dismiss()
                    }

                    Timer {
                        interval: 30000
                        running: true
                        repeat: false
                        onTriggered: toast.dismiss()
                    }

                    Timer {
                        id: removeTimer
                        interval: 100
                        repeat: false
                        onTriggered: root.dismissToast(toast.toastId)
                    }
                }
            }
        }
    }
}
