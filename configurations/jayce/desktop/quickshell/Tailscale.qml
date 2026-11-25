pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool known: false
    property string backendState: ""
    property var exitNodes: []
    property string exitNodeId: ""
    property string exitNodeName: ""
    property bool exitNodeOnline: false
    property bool pending: false
    property string stateError: ""
    property string commandError: ""
    readonly property bool active: known && backendState === "Running"
    readonly property string error: commandError || stateError
    readonly property string status: error || (pending ? "Changing…"
        : !known ? "Checking…"
        : backendState === "Stopped" ? "Off"
        : backendState === "NeedsLogin" ? "Sign in from a terminal"
        : backendState === "NeedsMachineAuth" ? "Awaiting device approval"
        : !active ? "Connecting…"
        : exitNodeId.length > 0 ? "Exit: " + exitNodeName + (exitNodeOnline ? "" : " · offline")
        : "On · no exit node")

    function refresh(): void {
        if (!statusProcess.running && !pending)
            statusProcess.running = true
    }

    function run(args: var): void {
        if (pending || !known)
            return
        commandError = ""
        pending = true
        command.command = ["timeout", "15s", "tailscale"].concat(args)
        command.running = true
    }

    function toggle(): void {
        if (active)
            run(["down"])
        else if (backendState === "Stopped")
            // Even --timeout bypasses the bare-up path that preserves preferences.
            run(["up"])
    }

    function selectExitNode(address: string): void {
        if (active)
            run(["set", "--exit-node=" + address])
    }

    function readStatus(text: string): void {
        try {
            const data = JSON.parse(text)
            if (typeof data.BackendState !== "string")
                throw new Error("Missing backend state")
            backendState = data.BackendState
            const selected = data.ExitNodeStatus
            exitNodeId = selected ? String(selected.ID) : ""
            exitNodeOnline = selected !== undefined && selected !== null && selected.Online === true
            const peers = Object.values(data.Peer || {})
            exitNodes = peers.filter(peer => peer.ExitNodeOption || peer.ID === exitNodeId)
                .map(peer => ({ id: String(peer.ID), name: peer.DNSName ? peer.DNSName.replace(/\.$/, "").split(".")[0] : peer.HostName,
                    address: (peer.TailscaleIPs || [])[0] || "", online: peer.Online === true }))
                .sort((left, right) => (right.online - left.online) || left.name.localeCompare(right.name))
            const node = exitNodes.find(peer => peer.id === exitNodeId)
            exitNodeName = node ? node.name : "Selected exit node"
            known = true
            stateError = ""
        } catch (error) {
            known = false
            stateError = "Cannot read Tailscale state"
        }
    }

    Process {
        id: statusProcess
        command: ["tailscale", "status", "--json"]
        running: true
        stdout: StdioCollector { id: statusOutput }
        stderr: StdioCollector {}
        onExited: function(exitCode, exitStatus) {
            if (exitStatus === 0 && exitCode === 0)
                root.readStatus(statusOutput.text)
            else {
                root.known = false
                root.stateError = "Tailscale is unavailable"
            }
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    Process {
        id: command
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: function(exitCode, exitStatus) {
            root.pending = false
            if (exitStatus !== 0 || exitCode !== 0)
                root.commandError = "Could not change Tailscale. Check login and operator permissions."
            root.refresh()
        }
    }
}
