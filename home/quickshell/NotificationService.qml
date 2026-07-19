import Quickshell
import Quickshell.Services.Notifications

Scope {
    id: root

    property alias notifications: server.trackedNotifications
    property alias dnd: persistent.dnd
    property bool centerVisible: false
    readonly property int count: notifications.values.length

    function toggleCenter() {
        centerVisible = !centerVisible
    }

    function clearAll() {
        const current = [...notifications.values]
        for (const notification of current)
            notification.dismiss()
    }

    PersistentProperties {
        id: persistent
        property bool dnd: false
    }

    NotificationServer {
        id: server
        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        bodyMarkupSupported: false
        actionsSupported: true
        imageSupported: true

        onNotification: function(notification) {
            notification.tracked = true
        }
    }
}
