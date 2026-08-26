pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Scope {
    id: root

    readonly property string allMode: "all"
    readonly property string criticalMode: "critical"
    readonly property string noneMode: "none"
    property string mode: allMode
    property bool centerOpen: false
    readonly property int maxHistoryEntries: 1000
    readonly property int maxPendingTransients: 100
    property alias history: historyModel
    property alias toasts: toastModel
    property int unreadCount: 0

    property int nextEntry: 0
    property real lastSoundAt: 0
    property var appSoundAt: ({})
    property var idToKey: ({})
    property var liveByKey: ({})
    property var connected: ({})
    property var pendingRefresh: ({})
    property var pendingTransientExpiry: ({})

    function appKey(notification): string {
        let value = String(notification.desktopEntry || "").trim().toLowerCase().replace(/\.desktop$/, "")
        if (value.length > 0)
            return value
        value = String(notification.appName || "").trim().toLowerCase()
        return value.length > 0 ? value : "unknown"
    }

    function newKey(): string {
        return "entry-" + Date.now().toString(36) + "-" + (++nextEntry).toString(36)
    }

    function urgencyValue(value): int {
        const numeric = Number(value)
        return isFinite(numeric) ? numeric : 1
    }

    function scalar(notification, key, timestamp, unread): var {
        return { entryKey: key, notificationId: Number(notification.id), appKey: appKey(notification),
            appName: String(notification.appName || ""), desktopEntry: String(notification.desktopEntry || ""),
            appIcon: String(notification.appIcon || ""), image: String(notification.image || ""),
            summary: String(notification.summary || ""), body: String(notification.body || ""),
            urgency: urgencyValue(notification.urgency), timestamp: timestamp, unread: unread }
    }

    function rowIndex(key): int {
        for (let i = 0; i < historyModel.count; i++)
            if (historyModel.get(i).entryKey === key)
                return i
        return -1
    }

    function findHistoryIndex(key: string): int { return rowIndex(key) }
    function isLive(key: string): bool { return liveByKey[key] !== undefined && liveByKey[key] !== null }
    function liveNotification(key: string): var { return liveByKey[key] || null }
    function unreadEntries(): int {
        let total = 0
        for (let i = 0; i < historyModel.count; i++)
            if (historyModel.get(i).unread) total++
        return total
    }
    function recalculateUnread(): void { unreadCount = unreadEntries() }

    function hasToast(key: string): bool {
        for (let i = 0; i < toastModel.count; i++)
            if (toastModel.get(i).entryKey === key) return true
        return false
    }

    function cancelTransientExpiry(key: string): void { delete pendingTransientExpiry[key] }

    function scheduleTransientExpiry(key: string, notification): void {
        if (!notification.transient || hasToast(key)) { cancelTransientExpiry(key); return }
        let milliseconds = Number(notification.expireTimeout)
        if (!isFinite(milliseconds) || milliseconds <= 0) milliseconds = 5000
        milliseconds = Math.min(milliseconds, 3600000)
        const created = Date.now()
        pendingTransientExpiry[key] = { notification: notification, created: created, deadline: created + milliseconds }
        enforcePendingTransientCap()
    }

    function enforcePendingTransientCap(): void {
        function pendingCount(): int {
            let count = 0
            for (const ignored in pendingTransientExpiry) count++
            return count
        }
        while (pendingCount() > maxPendingTransients) {
            let oldestKey = ""
            let oldest = Infinity
            for (const key in pendingTransientExpiry) {
                const pending = pendingTransientExpiry[key]
                if (pending.created < oldest) { oldest = pending.created; oldestKey = key }
            }
            if (oldestKey.length === 0) break
            const pending = pendingTransientExpiry[oldestKey]
            delete pendingTransientExpiry[oldestKey]
            if (liveByKey[oldestKey] === pending.notification && pending.notification.transient && !hasToast(oldestKey)) {
                pending.notification.expire()
                forgetLive(oldestKey, pending.notification)
            }
        }
    }

    function expirePendingTransients(): void {
        const now = Date.now()
        for (const key in pendingTransientExpiry) {
            const pending = pendingTransientExpiry[key]
            if (pending.deadline > now) continue
            delete pendingTransientExpiry[key]
            if (liveByKey[key] === pending.notification && pending.notification.transient && !hasToast(key)) {
                pending.notification.expire()
                forgetLive(key, pending.notification)
            }
        }
    }

    function scheduleRefresh(key: string, notification): void {
        if (liveByKey[key] !== notification) return
        pendingRefresh[key] = notification
        refreshTimer.restart()
    }

    function refreshLive(key: string, notification): void {
        if (liveByKey[key] !== notification) return
        const app = appKey(notification)
        const index = rowIndex(key)
        if (notification.transient && index >= 0) {
            historyModel.remove(index)
        } else if (!notification.transient && index < 0) {
            const created = scalar(notification, key, Date.now(), true)
            created.live = true
            historyModel.insert(0, created)
        } else if (index >= 0) {
            const old = historyModel.get(index)
            const updated = scalar(notification, key, old.timestamp, !!old.unread)
            updated.live = true
            historyModel.set(index, updated)
        }
        let toastIndex = -1
        for (let i = 0; i < toastModel.count; i++)
            if (toastModel.get(i).entryKey === key) { toastIndex = i; break }
        if (toastIndex >= 0) {
            for (let i = toastModel.count - 1; i >= 0; i--)
                if (i !== toastIndex && toastModel.get(i).appKey === app) removeToast(toastModel.get(i).entryKey)
            toastIndex = -1
            for (let i = 0; i < toastModel.count; i++)
                if (toastModel.get(i).entryKey === key) { toastIndex = i; break }
            const toast = scalar(notification, key, Date.now(), true)
            toast.revision = ++nextEntry
            toastModel.set(toastIndex, toast)
            cancelTransientExpiry(key)
        } else {
            scheduleTransientExpiry(key, notification)
        }
        recalculateUnread()
        trimHistory()
        schedulePersist()
    }

    function flushRefreshes(): void {
        const refreshes = pendingRefresh
        pendingRefresh = ({})
        for (const key in refreshes) refreshLive(key, refreshes[key])
    }

    function persist(): void {
        const rows = []
        for (let i = 0; i < historyModel.count; i++) {
            const row = historyModel.get(i)
            rows.push({ entryKey: row.entryKey, notificationId: row.notificationId, appKey: row.appKey,
                appName: row.appName, desktopEntry: row.desktopEntry, appIcon: row.appIcon, image: row.image,
                summary: row.summary, body: row.body, urgency: row.urgency, timestamp: row.timestamp, unread: !!row.unread })
        }
        stateFile.setText(JSON.stringify({ mode: mode, history: rows }))
    }

    function schedulePersist(): void { persistTimer.restart() }

    function validRow(row): bool {
        return row && typeof row.entryKey === "string" && typeof row.notificationId === "number"
            && typeof row.appKey === "string" && typeof row.timestamp === "number"
            && typeof row.summary === "string" && typeof row.body === "string"
    }

    function loadState(): void {
        if (!stateFile.loaded || stateFile.text().length === 0) return
        try {
            const data = JSON.parse(stateFile.text())
            if (data.mode === allMode || data.mode === criticalMode || data.mode === noneMode) mode = data.mode
            if (!Array.isArray(data.history)) return
            for (let i = 0; i < data.history.length && historyModel.count < maxHistoryEntries; i++) {
                const row = data.history[i]
                if (!validRow(row)) continue
                historyModel.append({ entryKey: row.entryKey, notificationId: row.notificationId,
                    appKey: row.appKey, appName: String(row.appName || ""), desktopEntry: String(row.desktopEntry || ""),
                    appIcon: String(row.appIcon || ""), image: String(row.image || ""), summary: row.summary,
                    body: row.body, urgency: Number(row.urgency) || 1, timestamp: row.timestamp, unread: !!row.unread, live: false })
            }
            recalculateUnread()
        } catch (error) { console.warn("notification history could not be loaded") }
    }

    function removeToast(key: string): void {
        for (let i = toastModel.count - 1; i >= 0; i--)
            if (toastModel.get(i).entryKey === key) toastModel.remove(i)
        if (rowIndex(key) < 0 && liveByKey[key]) {
            const notification = liveByKey[key]
            notification.expire()
            forgetLive(key, notification)
        }
        cancelTransientExpiry(key)
    }

    function forgetLive(key: string, notification): void {
        if (liveByKey[key] !== notification) return
        cancelTransientExpiry(key)
        delete pendingRefresh[key]
        delete liveByKey[key]
        if (idToKey[notification.id] === key) delete idToKey[notification.id]
        if (connected[key] === notification) delete connected[key]
    }

    function addToast(key: string, notification): void {
        const app = appKey(notification)
        for (let i = toastModel.count - 1; i >= 0; i--)
            if (toastModel.get(i).appKey === app) removeToast(toastModel.get(i).entryKey)
        while (toastModel.count >= 3) removeToast(toastModel.get(0).entryKey)
        const row = scalar(notification, key, Date.now(), true)
        row.revision = ++nextEntry
        row.appKey = app
        toastModel.append(row)
        cancelTransientExpiry(key)
    }

    function onNotification(notification): void {
        notification.tracked = true
        const app = appKey(notification)
        const oldKey = idToKey[notification.id]
        let key = oldKey || ""
        const replacement = oldKey !== undefined && oldKey !== null && oldKey !== ""
        if (!key && notification.lastGeneration) {
            for (let i = 0; i < historyModel.count; i++) {
                const row = historyModel.get(i)
                if (row.notificationId === Number(notification.id) && row.appKey === app) { key = row.entryKey; break }
            }
        }
        if (!key) key = newKey()
        idToKey[notification.id] = key
        liveByKey[key] = notification
        if (rowIndex(key) >= 0) {
            const index = rowIndex(key), old = historyModel.get(index)
            const updated = scalar(notification, key, old.timestamp, !!old.unread)
            updated.live = true
            historyModel.set(index, updated)
        } else if (!notification.transient) {
            const created = scalar(notification, key, Date.now(), true)
            created.live = true
            historyModel.insert(0, created)
        }
        if (connected[key] !== notification) {
            connected[key] = notification
            notification.closed.connect(function() { root.onClosed(key, notification) })
            const changed = ["expireTimeoutChanged", "appNameChanged", "appIconChanged", "summaryChanged",
                "bodyChanged", "urgencyChanged", "actionsChanged", "residentChanged", "transientChanged",
                "desktopEntryChanged", "imageChanged", "hasInlineReplyChanged", "inlineReplyPlaceholderChanged", "hintsChanged"]
            for (const signalName of changed)
                if (notification[signalName]) notification[signalName].connect(function() { root.scheduleRefresh(key, notification) })
        }
        const eligibleToast = mode === allMode || (mode === criticalMode && notification.urgency === NotificationUrgency.Critical)
        if (!notification.lastGeneration && !replacement) {
            if (eligibleToast && !centerOpen)
                addToast(key, notification)
            const hints = notification.hints || {}
            const suppressed = hints["suppress-sound"] === true || hints["suppress-sound"] === 1
                || hints.suppressSound === true || hints.suppressSound === 1
            const now = Date.now(), prior = Number(appSoundAt[app]) || 0
            if (mode === allMode && !suppressed && now - lastSoundAt >= 400 && now - prior >= 2000) {
                if (sound.play()) { lastSoundAt = now; appSoundAt[app] = now }
            }
        } else if (replacement && eligibleToast && !centerOpen) {
            for (let i = 0; i < toastModel.count; i++) {
                if (toastModel.get(i).entryKey !== key) continue
                for (let j = toastModel.count - 1; j >= 0; j--)
                    if (j !== i && toastModel.get(j).appKey === app) removeToast(toastModel.get(j).entryKey)
                let visibleIndex = -1
                for (let j = 0; j < toastModel.count; j++)
                    if (toastModel.get(j).entryKey === key) { visibleIndex = j; break }
                if (visibleIndex >= 0) {
                    const toast = scalar(notification, key, Date.now(), true)
                    toast.revision = ++nextEntry
                    toastModel.set(visibleIndex, toast)
                }
                break
            }
        }
        recalculateUnread()
        trimHistory()
        scheduleTransientExpiry(key, notification)
        schedulePersist()
    }

    function onClosed(key: string, notification): void {
        if (liveByKey[key] !== notification) return
        forgetLive(key, notification)
        removeToast(key)
        const index = rowIndex(key)
        if (index >= 0) historyModel.remove(index)
        recalculateUnread()
        schedulePersist()
    }

    function trimHistory(): void {
        while (historyModel.count > maxHistoryEntries) {
            const key = historyModel.get(historyModel.count - 1).entryKey
            if (isLive(key)) {
                const notification = liveByKey[key]
                notification.expire()
                if (notification.transient) forgetLive(key, notification)
            }
            removeToast(key)
            const index = rowIndex(key)
            if (index >= 0) historyModel.remove(index)
        }
        recalculateUnread()
        schedulePersist()
    }

    function markAllRead(): void { for (let i = 0; i < historyModel.count; i++) historyModel.setProperty(i, "unread", false); recalculateUnread(); schedulePersist() }
    function hideToast(key: string): void { removeToast(key) }
    function dismissEntry(key: string): void {
        const n = liveByKey[key]
        if (n) n.dismiss()
        removeToast(key)
        const i = rowIndex(key)
        if (i >= 0) historyModel.remove(i)
        if (n) forgetLive(key, n)
        recalculateUnread()
        schedulePersist()
    }
    function clear(): void {
        for (let i = historyModel.count - 1; i >= 0; i--) dismissEntry(historyModel.get(i).entryKey)
        while (toastModel.count > 0) removeToast(toastModel.get(0).entryKey)
    }
    function clearApp(app: string): void {
        for (let i = historyModel.count - 1; i >= 0; i--) if (historyModel.get(i).appKey === app) dismissEntry(historyModel.get(i).entryKey)
        for (let i = toastModel.count - 1; i >= 0; i--) if (toastModel.get(i).appKey === app) removeToast(toastModel.get(i).entryKey)
    }
    function toggle(): void { if (centerOpen) close(); else open() }
    function open(): void {
        centerOpen = true
        while (toastModel.count > 0) removeToast(toastModel.get(0).entryKey)
        markAllRead()
    }
    function close(): void { centerOpen = false }
    function setMode(value: string): void {
        if ([allMode, criticalMode, noneMode].indexOf(value) < 0) return
        mode = value
        for (let i = toastModel.count - 1; i >= 0; i--) {
            const row = toastModel.get(i)
            if (value === noneMode || (value === criticalMode && row.urgency !== NotificationUrgency.Critical))
                removeToast(row.entryKey)
        }
        schedulePersist()
    }
    function cycleMode(): void { setMode(mode === allMode ? criticalMode : mode === criticalMode ? noneMode : allMode) }
    function invokeAction(key: string, identifier: string): bool { const n = liveByKey[key]; if (!n) return false; for (const action of n.actions) if (action.identifier === identifier) { action.invoke(); if (liveByKey[key] === n) dismissEntry(key); return true } return false }
    function invokeDefault(key: string): bool { const n = liveByKey[key]; if (!n) return false; for (const action of n.actions) if (action.identifier === "default") { action.invoke(); if (liveByKey[key] === n) dismissEntry(key); return true } return false }
    function sendInlineReply(key: string, reply: string): bool { const n = liveByKey[key]; if (!n || !n.hasInlineReply) return false; n.sendInlineReply(reply); if (liveByKey[key] === n) dismissEntry(key); return true }
    function actionDescriptors(key: string): var { const n = liveByKey[key]; return n ? n.actions : [] }

    ListModel { id: historyModel }
    ListModel { id: toastModel }

    FileView { id: stateFile; path: Quickshell.statePath("notifications-history.json"); atomicWrites: true; preload: true; blockLoading: true; printErrors: false; onLoaded: root.loadState(); onSaveFailed: console.warn("notification history save failed") }
    Timer { id: persistTimer; interval: 250; onTriggered: root.persist() }
    Timer { id: refreshTimer; interval: 0; onTriggered: root.flushRefreshes() }
    Timer { id: transientExpiryTimer; interval: 500; repeat: true; running: true; onTriggered: root.expirePendingTransients() }
    NotificationSoundPlayer { id: sound }
    NotificationServer {
        id: server
        bodySupported: true; imageSupported: true; bodyImagesSupported: false; bodyMarkupSupported: false
        bodyHyperlinksSupported: false; actionsSupported: true; inlineReplySupported: true
        persistenceSupported: true; actionIconsSupported: false; keepOnReload: true
        onNotification: function(notification) { root.onNotification(notification) }
    }
    IpcHandler {
        target: "notifications"
        function toggle(): void { root.toggle() }
        function open(): void { root.open() }
        function close(): void { root.close() }
        function setMode(value: string): void { root.setMode(value) }
        function cycleMode(): void { root.cycleMode() }
        function clear(): void { root.clear() }
        function status(): string { return root.mode }
    }
}
