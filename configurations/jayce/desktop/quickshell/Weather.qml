pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The weather `wave watch` last sent to the watch, from MET Norway, named
// after the place GeoClue and Nominatim report.
Scope {
    id: root

    property var current: null
    readonly property bool known: current !== null
    readonly property var condition: classify(known ? current.symbol : "")
    readonly property string temperature: known ? Math.round(current.temperature) + "°" : ""
    readonly property string summary: !known ? ""
        : [current.place, condition.text, Math.round(current.minimum) + "–" + Math.round(current.maximum) + "°"]
            .filter(part => part).join(" · ")
    readonly property string icon: Quickshell.shellDir + "/assets/weather-" + condition.icon + ".svg"

    // The file is replaced by a rename, which can end the inotify watch.
    function reload(): void {
        file.reload()
    }

    // MET Norway symbol codes: a kind such as "lightrainshowers", then
    // _day, _night or _polartwilight.
    function classify(symbol: string): var {
        const kind = String(symbol || "").split("_")[0]
        const night = String(symbol || "").endsWith("_night")
        const intensity = kind.startsWith("light") ? "Light " : kind.startsWith("heavy") ? "Heavy " : ""
        const named = word => intensity ? intensity + word.toLowerCase() : word
        if (kind.includes("thunder")) return { icon: "thunderstorms", text: "Thunderstorm" }
        if (kind.includes("snow")) return { icon: "snowy", text: named("Snow") }
        if (kind.includes("sleet")) return { icon: "snowy", text: named("Sleet") }
        if (kind === "fog") return { icon: "foggy", text: "Fog" }
        if (kind.endsWith("showers")) return { icon: "showers", text: named("Showers") }
        if (kind.includes("rain")) return { icon: "rainy", text: named("Rain") }
        if (kind === "clearsky") return { icon: night ? "moon" : "sun", text: "Clear" }
        if (kind === "fair") return { icon: night ? "moon-cloudy" : "sun-cloudy", text: "Fair" }
        if (kind === "partlycloudy") return { icon: night ? "moon-cloudy" : "sun-cloudy", text: "Partly cloudy" }
        return { icon: "cloudy", text: kind === "cloudy" ? "Cloudy" : "Unknown" }
    }

    FileView {
        id: file
        path: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/wave/weather.json"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root.current = JSON.parse(text())
            } catch (error) {
                root.current = null
            }
        }
        onLoadFailed: root.current = null
    }
}
