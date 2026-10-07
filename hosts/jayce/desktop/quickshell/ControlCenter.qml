pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.UPower
import Quickshell.Wayland
import "Theme.js" as Theme

Scope {
    id: root
    required property var service
    required property var caffeinateService
    required property var watchService
    required property var targetScreen
    property string section: ""
    property string passwordFor: ""
    property string wifiError: ""
    property bool bluetoothScan: false
    readonly property var wifiDevice: {
        for (const device of Networking.devices.values) {
            if (device.type === DeviceType.Wifi)
                return device
        }
        return null
    }
    readonly property var activeNetwork: {
        if (wifiDevice === null)
            return null
        for (const network of wifiDevice.networks.values) {
            if (network.connected)
                return network
        }
        return null
    }
    readonly property var networks: wifiDevice === null ? [] : [...wifiDevice.networks.values]
        .filter(network => network.name.length > 0)
        .sort((left, right) => (right.connected - left.connected)
            || (right.known - left.known)
            || (right.signalStrength - left.signalStrength))
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var bluetoothDevices: adapter === null ? [] : [...adapter.devices.values]
        .filter(device => device.paired || device.bonded || (root.bluetoothScan && device.deviceName.length > 0))
        .sort((left, right) => (right.connected - left.connected)
            || ((right.paired || right.bonded) - (left.paired || left.bonded))
            || left.name.localeCompare(right.name))
    readonly property var connectedBluetooth: bluetoothDevices.filter(device => device.connected)
    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: battery.ready && battery.isPresent && battery.isLaptopBattery

    function toggleSection(name: string): void {
        section = section === name ? "" : name
        passwordFor = ""
        wifiError = ""
    }

    function wifiIcon(strength: real): string {
        return Quickshell.shellDir + "/assets/signal-wifi-" + Math.max(1, Math.ceil(strength * 4)) + ".svg"
    }

    function needsPassword(network): bool {
        return !network.known && network.security !== WifiSecurityType.Open && network.security !== WifiSecurityType.Owe
    }

    function activateNetwork(network): void {
        wifiError = ""
        if (network.connected) {
            network.disconnect()
            passwordFor = ""
        } else if (needsPassword(network)) {
            passwordFor = passwordFor === network.name ? "" : network.name
        } else {
            passwordFor = ""
            network.connect()
        }
    }

    function bluetoothIcon(icon: string): string {
        const kind = String(icon || "")
        const file = kind.indexOf("audio-head") === 0 ? "audio-headphones.svg"
            : kind.indexOf("audio") === 0 ? "audio-speakers.svg"
            : kind === "input-keyboard" ? "keyboard.svg"
            : kind === "input-mouse" || kind === "input-tablet" ? "mouse.svg"
            : kind === "phone" ? "smartphone.svg"
            : kind === "computer" ? "audio-built-in.svg"
            : "device.svg"
        return Quickshell.shellDir + "/assets/" + file
    }

    function activateDevice(device): void {
        if (device.connected)
            device.disconnect()
        else if (device.paired || device.bonded)
            device.connect()
        else if (device.pairing)
            device.cancelPair()
        else
            device.pair()
    }

    function deviceStatus(device): string {
        if (device.pairing)
            return "Pairing…"
        if (device.state === BluetoothDeviceState.Connecting)
            return "Connecting…"
        if (device.state === BluetoothDeviceState.Disconnecting)
            return "Disconnecting…"
        if (device.connected)
            return device.batteryAvailable ? "Connected · " + Math.round(device.battery * 100) + "%" : "Connected"
        return device.paired || device.bonded ? "Paired" : "Click to pair"
    }

    function formatDuration(seconds: real): string {
        if (seconds <= 0)
            return ""
        const hours = Math.floor(seconds / 3600)
        const minutes = Math.floor((seconds % 3600) / 60)
        return hours > 0 ? hours + "h " + minutes + "m" : minutes + "m"
    }

    function batteryStatus(): string {
        const percentage = Math.floor(battery.percentage * 100) + "%"
        if (battery.state === UPowerDeviceState.Charging) {
            const remaining = formatDuration(battery.timeToFull)
            return remaining ? percentage + " · " + remaining + " to full" : percentage + " · charging"
        }
        if (battery.state === UPowerDeviceState.Discharging) {
            const remaining = formatDuration(battery.timeToEmpty)
            return remaining ? percentage + " · " + remaining + " left" : percentage
        }
        if (battery.state === UPowerDeviceState.FullyCharged)
            return percentage + " · full"
        return percentage
    }

    function profileName(): string {
        return PowerProfiles.profile === PowerProfile.Performance ? "Performance"
            : PowerProfiles.profile === PowerProfile.PowerSaver ? "Power saver"
            : "Balanced"
    }

    function toggleProfile(): void {
        PowerProfiles.profile = PowerProfiles.profile === PowerProfile.PowerSaver
            ? (PowerProfiles.hasPerformanceProfile ? PowerProfile.Performance : PowerProfile.Balanced)
            : PowerProfile.PowerSaver
    }

    function caffeinateStatus(): string {
        if (caffeinateService.error.length > 0)
            return caffeinateService.error
        if (caffeinateService.pending)
            return "Changing mode…"
        if (!caffeinateService.known)
            return "Checking…"
        return caffeinateService.active ? "Tasks keep running" : "Automatic sleep"
    }

    component Icon: Image {
        width: 14
        height: 14
        sourceSize.width: width
        sourceSize.height: height
        fillMode: Image.PreserveAspectFit
        opacity: 0.85
    }

    component IconButton: Item {
        id: iconButton
        property alias source: buttonIcon.source
        signal clicked()
        width: 24
        height: 24
        Icon { id: buttonIcon; anchors.centerIn: parent; width: 13; height: 13; opacity: buttonPointer.containsMouse ? 1 : 0.75 }
        MouseArea { id: buttonPointer; anchors.fill: parent; hoverEnabled: true; onClicked: iconButton.clicked() }
    }

    component Tile: Rectangle {
        id: tile
        property string icon
        property string title
        property string subtitle
        property bool checked: false
        property bool expandable: false
        property bool expanded: false
        property bool alert: false
        default property alias iconContent: tileIcon.data
        signal toggled()
        signal expandToggled()
        height: 46
        radius: 8
        color: tile.checked ? Theme.waveBlue1 : Theme.notificationSurfaceRaised
        border.width: tile.expanded || tile.alert ? 1 : 0
        border.color: tile.alert ? Theme.waveRed : Theme.waveBlue2
        Behavior on color { ColorAnimation { duration: Theme.normalDuration } }

        MouseArea {
            id: tilePointer
            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
            anchors.right: tile.expandable ? chevron.left : parent.right
            hoverEnabled: true
            onClicked: tile.toggled()
        }
        Item {
            id: tileIcon
            anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
            width: 16; height: 16
            opacity: tile.checked ? 1 : 0.7
            Icon { anchors.fill: parent; visible: tile.icon.length > 0; source: tile.icon; opacity: 1 }
        }
        Column {
            anchors.left: tileIcon.right; anchors.leftMargin: 10
            anchors.right: tile.expandable ? chevron.left : parent.right; anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text { width: parent.width; text: tile.title; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: Font.DemiBold; elide: Text.ElideRight }
            Text { width: parent.width; text: tile.subtitle; color: tile.alert ? Theme.waveRed : tile.checked ? Theme.oldWhite : Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 10; elide: Text.ElideRight }
        }
        Rectangle {
            id: chevron
            visible: tile.expandable
            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: 30
            radius: tile.radius
            color: chevronPointer.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
            Icon { anchors.centerIn: parent; width: 14; height: 14; source: Quickshell.shellDir + (tile.expanded ? "/assets/chevron-down.svg" : "/assets/chevron-right.svg") }
            MouseArea { id: chevronPointer; anchors.fill: parent; hoverEnabled: true; onClicked: tile.expandToggled() }
        }
        scale: tilePointer.pressed ? 0.98 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fastDuration; easing.type: Easing.OutCubic } }
    }

    component ListRow: Rectangle {
        id: listRow
        property string icon
        property string title
        property string subtitle
        property bool highlighted: false
        property bool busy: false
        default property alias trailing: trailingRow.data
        signal clicked()
        width: parent ? parent.width : 0
        height: 34
        radius: Theme.notificationSmallRadius
        color: rowPointer.containsMouse ? Theme.sumiInk3 : "transparent"
        opacity: listRow.busy ? 0.65 : 1
        MouseArea { id: rowPointer; anchors.fill: parent; hoverEnabled: true; onClicked: listRow.clicked() }
        Icon { id: rowIcon; anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter; source: listRow.icon; opacity: listRow.highlighted ? 1 : 0.7 }
        Column {
            anchors.left: rowIcon.right; anchors.leftMargin: 9
            anchors.right: trailingRow.left; anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            Text { width: parent.width; text: listRow.title; color: listRow.highlighted ? Theme.crystalBlue : Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: listRow.highlighted ? Font.DemiBold : Font.Normal; elide: Text.ElideRight }
            Text { width: parent.width; visible: text.length > 0; text: listRow.subtitle; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 10; elide: Text.ElideRight }
        }
        Row { id: trailingRow; anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; spacing: 4 }
    }
    property var groups: []
    property var expanded: ({})
    property bool rebuilding: false
    property bool windowVisible: false
    property bool panelShown: false

    Component.onCompleted: {
        rebuild()
        if (service.centerOpen) {
            windowVisible = true
            panelShown = true
        }
    }

    function iconSource(value): string {
        const icon = String(value || "").trim()
        if (icon.indexOf("/") === 0 || /^(file|image|qrc):/i.test(icon)) return icon
        if (icon.length > 0 && icon.indexOf(":") < 0) {
            const resolved = Quickshell.iconPath(icon)
            if (resolved.indexOf("/") === 0 || /^(file|image|qrc):/i.test(resolved)) return resolved
        }
        return Quickshell.shellDir + "/assets/bell.svg"
    }

    function displayAppName(value): string {
        const name = String(value || "Unknown")
        const parts = name.split(".")
        return parts.length > 1 && parts[parts.length - 1].length > 0 ? parts[parts.length - 1] : name
    }

    function rebuildLater(): void {
        if (rebuilding) return
        rebuilding = true
        Qt.callLater(function() { rebuilding = false; rebuild() })
    }
    function rebuild(): void {
        const byApp = ({})
        for (let i = 0; i < service.history.count; i++) {
            const row = service.history.get(i)
            const key = String(row.appKey || "unknown")
            if (!byApp[key]) byApp[key] = { appKey: key, appName: row.appName, appIcon: row.appIcon, entries: [], newest: Number(row.timestamp) || 0 }
            byApp[key].entries.push({ entryKey: row.entryKey, notificationId: row.notificationId, appKey: row.appKey, appName: row.appName, appIcon: row.appIcon, desktopEntry: row.desktopEntry, image: row.image, summary: row.summary, body: row.body, urgency: row.urgency, timestamp: row.timestamp, unread: row.unread })
            if (!byApp[key].appIcon) byApp[key].appIcon = row.appIcon || row.desktopEntry
            byApp[key].newest = Math.max(byApp[key].newest, Number(row.timestamp) || 0)
        }
        const result = Object.keys(byApp).map(function(key) {
            const group = byApp[key]
            group.entries.sort(function(a, b) { return Number(b.timestamp) - Number(a.timestamp) })
            group.expanded = !!root.expanded[key]
            return group
        })
        result.sort(function(a, b) { return b.newest - a.newest })
        groups = result
    }

    Connections {
        target: root.service.history
        ignoreUnknownSignals: true
        function onCountChanged() { root.rebuildLater() }
        function onDataChanged() { root.rebuildLater() }
        function onRowsInserted() { root.rebuildLater() }
        function onRowsRemoved() { root.rebuildLater() }
        function onModelReset() { root.rebuildLater() }
    }
    Connections {
        target: root.service
        function onCenterOpenChanged() {
            if (root.service.centerOpen) {
                root.windowVisible = true
                root.rebuildLater()
                root.panelShown = true
                hideTimer.stop()
            } else {
                root.panelShown = false
                root.passwordFor = ""
                root.bluetoothScan = false
                hideTimer.restart()
            }
        }
    }

    // Both scans stop again (restoring the previous value) once the panel closes.
    Binding {
        when: root.wifiDevice !== null && root.windowVisible && root.section === "wifi"
        target: root.wifiDevice
        property: "scannerEnabled"
        value: true
    }

    Binding {
        when: root.adapter !== null && root.adapter.enabled && root.windowVisible && root.bluetoothScan
        target: root.adapter
        property: "discovering"
        value: true
    }

    Timer {
        id: hideTimer
        interval: Theme.slowDuration + 30
        repeat: false
        onTriggered: if (!root.service.centerOpen) root.windowVisible = false
    }

    PanelWindow {
        id: window
        screen: root.targetScreen
        visible: root.targetScreen !== null && root.windowVisible
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        anchors { top: true; right: true; bottom: true; left: true }
        mask: Region { item: root.windowVisible ? outside : null }
        onVisibleChanged: if (visible) Qt.callLater(function() { panel.forceActiveFocus() })

        MouseArea { id: outside; anchors.fill: parent; onClicked: root.service.close() }

        Rectangle {
            id: panel
            width: Math.max(280, Math.min(Theme.controlCenterWidth, window.width - 24))
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            property real panelOffset: -8
            anchors.topMargin: Theme.notificationBarHeight + 12 + panelOffset
            readonly property real minimumHeight: 120
            readonly property real maximumHeight: Math.max(minimumHeight, window.height - anchors.topMargin - 24)
            readonly property real padding: 14
            readonly property real naturalHeight: panel.padding * 2 + controls.height + header.height + panelContent.spacing * 2 + Math.max(list.implicitHeight, root.groups.length === 0 ? 64 : 0) + 6
            height: Math.min(maximumHeight, Math.max(minimumHeight, naturalHeight))
            opacity: 0
            scale: 0.985
            transformOrigin: Item.Top
            radius: Theme.notificationRadius; color: Theme.notificationSurface; border.width: 1; border.color: Theme.notificationBorder
            focus: true
            Keys.onEscapePressed: {
                if (root.passwordFor.length > 0)
                    root.passwordFor = ""
                else
                    root.service.close()
            }
            MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }
            Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
            states: State {
                name: "shown"
                when: root.panelShown
                PropertyChanges { panel.opacity: 1; panel.panelOffset: 0; panel.scale: 1 }
            }
            transitions: Transition {
                reversible: true
                ParallelAnimation {
                    NumberAnimation { properties: "opacity,panelOffset,scale"; duration: Theme.slowDuration; easing.type: Easing.OutCubic }
                }
            }

            Column {
                id: panelContent
                anchors.fill: parent; anchors.margins: panel.padding; spacing: 16
                Column {
                    id: controls
                    width: parent.width
                    spacing: 16

                    Item {
                        width: parent.width; height: 44
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 4; anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            SystemClock { id: clock; precision: SystemClock.Minutes }
                            Text { text: Qt.formatDateTime(clock.date, "HH:mm"); color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 20; font.weight: Font.Bold }
                            Text { text: Qt.formatDateTime(clock.date, "dddd, d MMMM yyyy"); color: Theme.oldWhite; font.family: Theme.fontFamily; font.pixelSize: 11 }
                        }
                        IconButton {
                            anchors.right: parent.right; anchors.top: parent.top
                            source: Quickshell.shellDir + "/assets/xmark.svg"
                            onClicked: root.service.close()
                        }
                    }

                    Flow {
                        id: tiles
                        width: parent.width
                        spacing: 8
                        readonly property real tileWidth: (width - spacing) / 2

                        Tile {
                            width: tiles.tileWidth
                            icon: root.wifiIcon(root.activeNetwork === null ? 1 : root.activeNetwork.signalStrength)
                            title: "Wi-Fi"
                            subtitle: root.wifiDevice === null ? "Unavailable"
                                : !Networking.wifiEnabled ? "Off"
                                : root.activeNetwork === null ? "Not connected"
                                : root.activeNetwork.name
                            checked: Networking.wifiEnabled && root.activeNetwork !== null
                            expandable: root.wifiDevice !== null
                            expanded: root.section === "wifi"
                            onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
                            onExpandToggled: root.toggleSection("wifi")
                        }

                        Tile {
                            width: tiles.tileWidth
                            icon: Quickshell.shellDir + (root.connectedBluetooth.length > 0 ? "/assets/bluetooth-connect.svg" : "/assets/bluetooth.svg")
                            title: "Bluetooth"
                            subtitle: root.adapter === null ? "Unavailable"
                                : !root.adapter.enabled ? "Off"
                                : root.connectedBluetooth.length > 0 ? root.connectedBluetooth.map(device => device.name).join(", ")
                                : "On"
                            checked: root.adapter !== null && root.adapter.enabled
                            expandable: root.adapter !== null
                            expanded: root.section === "bluetooth"
                            onToggled: if (root.adapter !== null) root.adapter.enabled = !root.adapter.enabled
                            onExpandToggled: root.toggleSection("bluetooth")
                        }

                        Tile {
                            width: tiles.tileWidth
                            title: root.hasBattery ? "Battery" : "Power"
                            subtitle: (root.hasBattery ? root.batteryStatus() + " · " : "") + root.profileName()
                            checked: PowerProfiles.profile === PowerProfile.Performance
                            alert: root.hasBattery && root.battery.percentage < 0.15
                            onToggled: root.toggleProfile()

                            BatteryIcon {
                                anchors.fill: parent
                                visible: root.hasBattery
                                level: root.battery.percentage
                                charging: root.battery.state === UPowerDeviceState.Charging
                            }
                        }

                        Tile {
                            width: tiles.tileWidth
                            icon: Quickshell.shellDir + (root.caffeinateService.active ? "/assets/coffee-steaming.svg" : "/assets/coffee.svg")
                            title: "Caffeinate"
                            subtitle: root.caffeinateStatus()
                            checked: root.caffeinateService.known && root.caffeinateService.active
                            alert: root.caffeinateService.error.length > 0
                            opacity: root.caffeinateService.pending ? 0.65 : 1
                            onToggled: root.caffeinateService.toggle()
                        }

                        Tile {
                            width: tiles.width
                            icon: Quickshell.shellDir + "/assets/watch.svg"
                            title: "Watch"
                            subtitle: root.watchService.status
                            checked: root.watchService.connected
                            onToggled: root.watchService.refresh()
                        }
                    }

                    Rectangle {
                        id: details
                        width: parent.width
                        visible: height > 0
                        height: root.section === "" ? 0 : Math.min(detailsColumn.implicitHeight, 260) + 12
                        clip: true
                        radius: 8
                        color: Theme.sumiInk0
                        Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }

                        Flickable {
                            anchors.fill: parent; anchors.margins: 6
                            contentWidth: width; contentHeight: detailsColumn.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds
                            clip: true

                            Column {
                                id: detailsColumn
                                width: parent.width
                                spacing: 2

                                Item {
                                    width: parent.width; height: 24
                                    Text {
                                        anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                        text: root.section === "wifi" ? "Networks" : "Devices"
                                        color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        anchors.right: scanButton.left; anchors.rightMargin: 2; anchors.verticalCenter: parent.verticalCenter
                                        visible: root.section === "bluetooth" && root.adapter !== null && root.adapter.discovering
                                        text: "Scanning…"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 10
                                    }
                                    IconButton {
                                        id: scanButton
                                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                        visible: root.section === "bluetooth" && root.adapter !== null && root.adapter.enabled
                                        source: Quickshell.shellDir + "/assets/refresh.svg"
                                        onClicked: root.bluetoothScan = !root.bluetoothScan
                                    }
                                }

                                Text {
                                    width: parent.width; leftPadding: 8
                                    visible: root.wifiError.length > 0 && root.section === "wifi"
                                    text: root.wifiError; color: Theme.waveRed; font.family: Theme.fontFamily; font.pixelSize: 10; wrapMode: Text.Wrap
                                }

                                Repeater {
                                    model: ScriptModel { values: root.section === "wifi" && Networking.wifiEnabled ? root.networks : [] }
                                    delegate: Column {
                                        id: networkDelegate
                                        required property var modelData
                                        width: detailsColumn.width
                                        spacing: 2

                                        Connections {
                                            target: networkDelegate.modelData
                                            function onConnectionFailed(reason) {
                                                root.wifiError = networkDelegate.modelData.name + ": " + ConnectionFailReason.toString(reason)
                                                if (reason === ConnectionFailReason.NoSecrets)
                                                    root.passwordFor = networkDelegate.modelData.name
                                            }
                                        }

                                        ListRow {
                                            icon: root.wifiIcon(networkDelegate.modelData.signalStrength)
                                            title: networkDelegate.modelData.name
                                            subtitle: networkDelegate.modelData.stateChanging
                                                ? (networkDelegate.modelData.connected ? "Disconnecting…" : "Connecting…")
                                                : networkDelegate.modelData.connected ? "Connected"
                                                : networkDelegate.modelData.known ? "Saved" : ""
                                            highlighted: networkDelegate.modelData.connected
                                            busy: networkDelegate.modelData.stateChanging
                                            onClicked: root.activateNetwork(networkDelegate.modelData)

                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: Math.round(networkDelegate.modelData.signalStrength * 100) + "%"
                                                color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 10
                                            }
                                            Icon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 12; height: 12
                                                opacity: 0.6
                                                visible: networkDelegate.modelData.security !== WifiSecurityType.Open && networkDelegate.modelData.security !== WifiSecurityType.Owe
                                                source: Quickshell.shellDir + "/assets/lock.svg"
                                            }
                                            IconButton {
                                                visible: networkDelegate.modelData.known && !networkDelegate.modelData.connected
                                                source: Quickshell.shellDir + "/assets/trash.svg"
                                                onClicked: networkDelegate.modelData.forget()
                                            }
                                        }

                                        Rectangle {
                                            visible: root.passwordFor === networkDelegate.modelData.name
                                            width: parent.width; height: 30
                                            radius: Theme.notificationSmallRadius
                                            color: Theme.sumiInk2
                                            border.width: 1; border.color: passwordInput.activeFocus ? Theme.waveBlue2 : Theme.sumiInk3
                                            onVisibleChanged: {
                                                passwordInput.text = ""
                                                if (visible) Qt.callLater(function() { passwordInput.forceActiveFocus() })
                                            }

                                            TextInput {
                                                id: passwordInput
                                                anchors.left: parent.left; anchors.right: connectButton.left
                                                anchors.leftMargin: 10; anchors.rightMargin: 6
                                                anchors.verticalCenter: parent.verticalCenter
                                                echoMode: TextInput.Password
                                                color: Theme.fujiWhite; selectionColor: Theme.waveBlue2
                                                font.family: Theme.fontFamily; font.pixelSize: 11
                                                clip: true
                                                Keys.onEscapePressed: root.passwordFor = ""
                                                onAccepted: connectButton.clicked()
                                                Text {
                                                    visible: passwordInput.text.length === 0
                                                    text: "Password"; color: Theme.fujiGray; font: passwordInput.font
                                                }
                                            }
                                            IconButton {
                                                id: connectButton
                                                anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter
                                                source: Quickshell.shellDir + "/assets/check.svg"
                                                onClicked: {
                                                    if (passwordInput.text.length === 0)
                                                        return
                                                    root.wifiError = ""
                                                    networkDelegate.modelData.connectWithPsk(passwordInput.text)
                                                    root.passwordFor = ""
                                                }
                                            }
                                        }
                                    }
                                }

                                Repeater {
                                    model: ScriptModel { values: root.section === "bluetooth" && root.adapter !== null && root.adapter.enabled ? root.bluetoothDevices : [] }
                                    delegate: ListRow {
                                        id: deviceDelegate
                                        required property var modelData
                                        property bool pairRequested: false
                                        width: detailsColumn.width
                                        icon: root.bluetoothIcon(modelData.icon)
                                        title: modelData.name
                                        subtitle: root.deviceStatus(modelData)
                                        highlighted: modelData.connected
                                        busy: modelData.pairing || modelData.state === BluetoothDeviceState.Connecting || modelData.state === BluetoothDeviceState.Disconnecting
                                        onClicked: {
                                            deviceDelegate.pairRequested = !modelData.paired && !modelData.bonded && !modelData.pairing
                                            root.activateDevice(modelData)
                                        }

                                        // A freshly paired device is trusted so it reconnects on its own later.
                                        Connections {
                                            target: deviceDelegate.modelData
                                            function onPairedChanged() {
                                                if (!deviceDelegate.pairRequested || !deviceDelegate.modelData.paired)
                                                    return
                                                deviceDelegate.pairRequested = false
                                                deviceDelegate.modelData.trusted = true
                                                deviceDelegate.modelData.connect()
                                            }
                                        }

                                        IconButton {
                                            visible: deviceDelegate.modelData.paired || deviceDelegate.modelData.bonded
                                            source: Quickshell.shellDir + "/assets/trash.svg"
                                            onClicked: deviceDelegate.modelData.forget()
                                        }
                                    }
                                }

                                Text {
                                    width: parent.width; leftPadding: 8; topPadding: 4; bottomPadding: 6
                                    visible: root.section === "bluetooth" ? root.adapter === null || !root.adapter.enabled || root.bluetoothDevices.length === 0
                                        : root.section === "wifi" && (!Networking.wifiEnabled || root.networks.length === 0)
                                    text: root.section === "bluetooth"
                                        ? (root.adapter === null || !root.adapter.enabled ? "Bluetooth is off" : "No devices. Use refresh to scan.")
                                        : !Networking.wifiEnabled ? "Wi-Fi is off" : "Searching for networks…"
                                    color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 10
                                }
                            }
                        }
                    }

                    Rectangle { width: parent.width; height: 1; color: Theme.notificationBorder; opacity: 0.6 }
                }
                Item {
                    id: header
                    width: parent.width; height: 30
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 4; anchors.verticalCenter: parent.verticalCenter; spacing: 7
                        Text { text: "Notifications"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: Font.DemiBold; verticalAlignment: Text.AlignVCenter }
                        Rectangle { visible: root.service.history.count > 0; width: 5; height: 5; radius: 2.5; color: Theme.crystalBlue; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Row { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                        Rectangle {
                            id: selector
                            width: 240; height: 30; radius: 8; color: Theme.notificationSurfaceRaised
                            Repeater {
                                model: [root.service.allMode, root.service.criticalMode, root.service.noneMode]
                                delegate: Rectangle {
                                    id: selectorDelegate
                                    required property int index
                                    required property string modelData
                                    readonly property bool selected: root.service.mode === selectorDelegate.modelData
                                    x: selectorDelegate.index * selector.width / 3 + 3; y: 3; width: selector.width / 3 - 6; height: selector.height - 6; radius: 6
                                    color: selectorDelegate.selected ? Theme.waveBlue1 : selectorPointer.containsMouse ? Theme.sumiInk3 : "transparent"
                                    Behavior on color { ColorAnimation { duration: Theme.normalDuration } }
                                    Row { anchors.centerIn: parent; spacing: 5; opacity: selectorDelegate.selected ? 1 : 0.6
                                        Icon { width: 12; height: 12; anchors.verticalCenter: parent.verticalCenter; opacity: 1; source: Quickshell.shellDir + "/assets/" + (selectorDelegate.modelData === root.service.allMode ? "bell.svg" : selectorDelegate.modelData === root.service.criticalMode ? "half-moon.svg" : "bell-off.svg") }
                                        Text { text: selectorDelegate.modelData === root.service.allMode ? "All" : selectorDelegate.modelData === root.service.criticalMode ? "Critical" : "None"; color: Theme.fujiWhite; font.family: Theme.fontFamily; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                                    }
                                    MouseArea { id: selectorPointer; anchors.fill: parent; hoverEnabled: true; onClicked: root.service.setMode(selectorDelegate.modelData) }
                                }
                            }
                        }
                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            opacity: root.service.history.count > 0 ? 1 : 0.3
                            enabled: root.service.history.count > 0
                            source: Quickshell.shellDir + "/assets/trash.svg"
                            onClicked: root.service.clear()
                        }
                    }
                }
                Flickable {
                    id: flick
                    width: parent.width; height: Math.max(1, panel.height - panel.padding * 2 - controls.height - header.height - panelContent.spacing * 2)
                    clip: true; contentWidth: width; contentHeight: Math.max(height, list.implicitHeight)
                    boundsBehavior: Flickable.StopAtBounds
                    Column { id: list; width: flick.width; spacing: 8
                        add: Transition { NumberAnimation { properties: "opacity,height"; duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                        move: Transition { NumberAnimation { properties: "y"; duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                        visible: root.groups.length > 0
                        Repeater {
                            model: root.groups
                            delegate: Rectangle {
                                id: groupDelegate
                                required property var modelData
                                property bool expandedState: !!modelData.expanded
                                width: list.width; radius: 8; color: Theme.notificationSurfaceRaised
                                height: groupContent.implicitHeight + 8
                                Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                                Column {
                                    id: groupContent
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                    anchors.leftMargin: Theme.notificationPadding; anchors.rightMargin: Theme.notificationPadding; anchors.topMargin: 4; spacing: 0
                                    Repeater {
                                         model: modelData.entries
                                         delegate: Column {
                                             id: cardDelegate
                                             required property int index
                                             required property var modelData
                                             width: groupContent.width; spacing: 0
                                             readonly property bool collapsed: cardDelegate.index > 0 && !groupDelegate.expandedState
                                             height: (cardDelegate.collapsed ? 0 : card.implicitHeight + (cardDelegate.index > 0 ? 5 : 0))
                                             opacity: cardDelegate.collapsed ? 0 : 1
                                             clip: true
                                             Behavior on height { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                                             Behavior on opacity { NumberAnimation { duration: Theme.normalDuration; easing.type: Easing.OutCubic } }
                                             Rectangle { visible: cardDelegate.index > 0; width: parent.width; height: 1; color: Theme.notificationBorder; opacity: 0.55 }
                                             NotificationCard {
                                                 id: card
                                                 width: parent.width; service: root.service; entry: cardDelegate.modelData
                                                 compact: groupDelegate.modelData.entries.length > 1 && !groupDelegate.expandedState
                                                 appName: cardDelegate.index === 0 ? root.displayAppName(groupDelegate.modelData.appName || groupDelegate.modelData.appKey) : ""
                                                 appIcon: cardDelegate.index === 0 ? root.iconSource(groupDelegate.modelData.appIcon) : ""
                                                 groupCount: cardDelegate.index === 0 ? groupDelegate.modelData.entries.length : 1
                                                 expanded: groupDelegate.expandedState
                                                 onToggleRequested: {
                                                     groupDelegate.expandedState = !groupDelegate.expandedState
                                                     const persisted = Object.assign({}, root.expanded)
                                                     persisted[groupDelegate.modelData.appKey] = groupDelegate.expandedState
                                                     root.expanded = persisted
                                                 }
                                             }
                                         }
                                    }
                                }
                            }
                        }
                    }
                     Text { anchors.centerIn: parent; visible: root.groups.length === 0; text: "No notifications"; color: Theme.fujiGray; font.family: Theme.fontFamily; font.pixelSize: 11 }
                }
            }
        }
    }
}
