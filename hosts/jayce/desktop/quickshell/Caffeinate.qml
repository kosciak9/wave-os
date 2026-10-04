pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool active: false
    property bool known: false
    property bool transitioning: false
    property bool queryPending: false
    property bool commandPending: false
    property bool confirming: false
    property bool requestedActive: false
    property string queryError: ""
    property string commandError: ""
    readonly property bool pending: commandPending || confirming || transitioning
    readonly property string error: commandError || queryError
    readonly property string status: commandPending || confirming
        ? requestedActive ? "Starting…" : "Stopping…"
        : transitioning ? "Updating…" : known ? active ? "ON" : "OFF" : "Unknown"

    function refresh(): void {
        if (queryPending || commandPending || query.running || command.running)
            return
        queryPending = true
        query.running = true
    }

    function toggle(): void {
        if (!known || pending || queryPending || query.running || command.running)
            return
        requestedActive = !active
        commandError = ""
        commandPending = true
        command.command = ["systemctl", "--user", requestedActive ? "start" : "stop", "wave-caffeinate.service"]
        command.running = true
    }

    Component.onCompleted: refresh()

    Timer {
        interval: 1500
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Process {
        id: query
        command: ["systemctl", "--user", "is-active", "wave-caffeinate.service"]
        environment: ({ LC_ALL: "C" })
        stdout: StdioCollector {
            id: stateOutput
            waitForEnd: true
        }
        stderr: StdioCollector {}

        onExited: function(exitCode, exitStatus) {
            if (!root.queryPending)
                return
            root.queryPending = false
            const state = stateOutput.text.trim()
            const wasActive = root.active
            root.transitioning = false
            root.queryError = ""
            if (exitStatus === 0 && exitCode === 0 && state === "active") {
                root.active = true
                root.known = true
            } else if (exitStatus === 0 && exitCode === 3 && (state === "inactive" || state === "failed")) {
                root.active = false
                root.known = true
                if (state === "failed")
                    root.queryError = "Caffeinate service failed. Click to retry."
            } else if (exitStatus === 0 && (state === "activating" || state === "deactivating" || state === "reloading")) {
                root.known = false
                root.transitioning = true
            } else {
                root.known = false
                root.queryError = "Cannot read caffeinate service state."
            }
            if (root.known && wasActive !== root.active)
                root.commandError = ""
            if (root.confirming && root.known && root.active !== root.requestedActive && root.commandError.length === 0)
                root.commandError = "Caffeinate did not reach the requested state. Click to retry."
            root.confirming = false
        }
    }

    Process {
        id: command
        stdout: StdioCollector {}
        stderr: StdioCollector {}

        onExited: function(exitCode, exitStatus) {
            if (!root.commandPending)
                return
            root.commandPending = false
            if (exitStatus !== 0 || exitCode !== 0)
                root.commandError = "Could not " + (root.requestedActive ? "start" : "stop") + " caffeinate. Click to retry."
            root.confirming = true
            root.refresh()
        }
    }

    // Failed-to-start does not emit exited; the watchdog also releases those requests.
    Timer {
        interval: root.commandPending ? 30000 : 10000
        running: root.queryPending || root.commandPending
        onTriggered: {
            if (root.commandPending) {
                root.commandPending = false
                root.commandError = "Caffeinate command timed out; checking service state."
                command.signal(9)
                root.confirming = true
            } else {
                root.queryPending = false
                root.known = false
                root.transitioning = false
                root.confirming = false
                root.queryError = "Caffeinate state query timed out."
                query.signal(9)
            }
        }
    }
}
