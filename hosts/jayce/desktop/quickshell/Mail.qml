pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Every neverest sync and every Bridge inbox change asks for a refresh over
// IPC, which keeps the bar's unread badge current.
Scope {
    id: root
    property var accounts: []
    property string discoveryError: ""
    readonly property int pageSize: 100
    property var inboxes: []
    property int queried: 0
    property int page: 1
    property var pendingEnvelopes: []
    property bool loading: false
    // A sync that lands while the mirror is being read gets one more pass.
    property bool stale: false
    readonly property int unreadCount: inboxes.reduce((total, inbox) => total
        + inbox.envelopes.filter(envelope => unread(envelope)).length, 0)

    function open(): void {
        Quickshell.execDetached(["vicinae", "cmd", "launch", "@wave-os/himalaya:inbox"])
    }

    function refresh(): void {
        if (loading) {
            stale = true
            return
        }
        loading = true
        stale = false
        queried = 0
        page = 1
        pendingEnvelopes = []
        discover.running = true
    }

    function finish(inbox): void {
        const next = inboxes.filter(other => other.account !== inbox.account)
        next.push(inbox)
        inboxes = next.sort((left, right) => accounts.indexOf(left.account) - accounts.indexOf(right.account))
        queried++
        page = 1
        pendingEnvelopes = []
        if (queried < accounts.length) {
            query.running = true
            return
        }
        finishRefresh()
    }

    function finishRefresh(): void {
        loading = false
        if (stale)
            refresh()
    }

    function unread(envelope): bool {
        return !envelope.flags.some(flag => flag.iana === "seen")
    }

    IpcHandler {
        target: "mail"
        function refresh(): void { root.refresh() }
    }

    Component.onCompleted: refresh()

    Process {
        id: discover
        command: ["himalaya", "account", "list", "--json"]
        stdout: StdioCollector { id: discoveryOutput }
        stderr: StdioCollector { id: discoveryStderr }
        onExited: function(exitCode, exitStatus) {
            try {
                if (exitCode !== 0 || exitStatus !== 0)
                    throw new Error(discoveryStderr.text.trim().split("\n").pop() || "himalaya failed.")
                const accounts = JSON.parse(discoveryOutput.text).accounts
                if (!Array.isArray(accounts) || accounts.some(account => typeof account.name !== "string" || account.name.length === 0))
                    throw new Error("Could not discover mail accounts.")
                root.accounts = accounts.map(account => account.name)
                root.discoveryError = ""
                root.inboxes = root.inboxes.filter(inbox => root.accounts.includes(inbox.account))
                if (root.accounts.length > 0) {
                    query.running = true
                    return
                }
            } catch (error) {
                root.discoveryError = error.message || "Could not discover mail accounts."
            }
            root.finishRefresh()
        }
    }

    Process {
        id: query
        readonly property string account: root.accounts[root.queried] || ""
        command: ["himalaya", "-a", account, "envelope", "list", "-s", String(root.pageSize), "-p", String(root.page), "--json"]
        stdout: StdioCollector { id: queryOutput }
        stderr: StdioCollector { id: queryError }
        onExited: function(exitCode, exitStatus) {
            const inbox = { account: query.account, envelopes: [], error: "" }
            try {
                if (exitCode !== 0 || exitStatus !== 0)
                    throw new Error(queryError.text.trim().split("\n").pop() || "himalaya failed.")
                const envelopes = JSON.parse(queryOutput.text).envelopes
                if (!Array.isArray(envelopes))
                    throw new Error("Could not read the inbox.")
                root.pendingEnvelopes = root.pendingEnvelopes.concat(envelopes)
                if (envelopes.length === root.pageSize) {
                    root.page++
                    query.running = true
                    return
                }
                inbox.envelopes = root.pendingEnvelopes
            } catch (error) {
                inbox.error = error.message || "Could not read the inbox."
                const previous = root.inboxes.find(other => other.account === inbox.account)
                inbox.envelopes = previous ? previous.envelopes : root.pendingEnvelopes
            }
            root.finish(inbox)
        }
    }
}
