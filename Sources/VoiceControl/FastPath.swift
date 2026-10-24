// Exact, unambiguous phrases are matched locally in ~0 ms and never reach the API.
import AppKit

enum FastPath {
    /// Lowercased, punctuation stripped, filler words removed: "Please open Notes." → "open notes".
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "%", with: " percent")
        t = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? String($0) : " " }.joined()
        let filler: Set<String> = ["please", "the", "a", "my", "hey", "ok", "okay", "now", "thanks", "thank", "you"]
        return t.split(separator: " ").map(String.init).filter { !filler.contains($0) }.joined(separator: " ")
    }

    static func squash(_ s: String) -> String { normalize(s).replacingOccurrences(of: " ", with: "") }

    static let phrases: [String: String] = {
        var m: [String: String] = [:]
        func add(_ value: String, _ ps: [String]) { for p in ps { m[normalize(p)] = value } }
        add("system:mute", ["mute", "unmute", "mute sound", "mute volume"])
        add("system:volumeup", ["volume up", "louder", "turn it up", "turn up volume", "turn volume up"])
        add("system:volumedown", ["volume down", "quieter", "turn it down", "turn down volume", "turn volume down"])
        add("system:brightnessup", ["brighter", "brightness up", "increase brightness"])
        add("system:brightnessdown", ["dimmer", "brightness down", "decrease brightness"])
        add("system:playpause", ["play", "pause", "play pause", "resume", "resume music", "pause music", "play music"])
        add("system:next", ["next song", "next track", "skip song", "skip track"])
        add("system:previous", ["previous song", "previous track", "last song"])
        add("system:lock", ["lock screen", "lock my mac", "lock computer"])
        add("system:sleepdisplay", ["sleep display", "turn off display", "turn off screen"])
        add("system:screenshot", ["screenshot", "take screenshot", "take a screenshot"])
        add("system:screenshotarea", ["screenshot area", "screenshot selection"])
        add("system:darkon", ["dark mode", "dark mode on", "turn on dark mode"])
        add("system:darkoff", ["light mode", "dark mode off", "turn off dark mode"])
        add("window:minimize", ["minimize", "minimize window"])
        add("window:maximize", ["maximize", "maximize window", "fill", "fill screen", "make it bigger"])
        add("window:fullscreen", ["full screen", "fullscreen", "toggle full screen", "exit full screen"])
        add("window:center", ["center", "center window"])
        add("window:left", ["left half", "snap left", "tile left", "move window left"])
        add("window:right", ["right half", "snap right", "tile right", "move window right"])
        add("window:top", ["top half", "tile top"])
        add("window:bottom", ["bottom half", "tile bottom"])
        add("window:close", ["close window"])
        add("window:nextdisplay", ["next display", "move to next display", "move to other display", "other display",
                                   "move to other screen", "other screen", "move window to other display"])
        add("browser:back", ["go back", "back"])
        add("browser:forward", ["go forward", "forward"])
        add("browser:reload", ["reload", "refresh", "reload page", "refresh page"])
        add("browser:newtab", ["new tab", "open new tab"])
        add("browser:closetab", ["close tab"])
        add("browser:reopentab", ["reopen tab", "reopen closed tab", "reopen last tab"])
        add("browser:scrolldown", ["scroll down", "page down"])
        add("browser:scrollup", ["scroll up", "page up"])
        add("undo", ["undo", "undo that", "undo last command"])
        return m
    }()

    static let openVerbs = ["open", "launch", "start", "switch to", "go to", "show"]
    static let quitVerbs = ["quit", "close", "exit", "kill"]

    /// Returns the actions to run, or nil to fall through to the API.
    static func match(_ heard: String, apps: [AppEntry], macros: [Macro]) -> [String]? {
        let n = normalize(heard)
        guard !n.isEmpty else { return nil }
        if let i = macros.firstIndex(where: { normalize($0.phrase) == n }) { return ["macro:\(i)"] }
        if let v = phrases[n] { return [v] }
        if let pct = volumeLevel(n) { return ["system:volume=\(pct)"] }
        for verb in openVerbs where n.hasPrefix(verb + " ") {
            let target = squash(String(n.dropFirst(verb.count + 1)))
            if let a = apps.first(where: { squash($0.name) == target }) { return ["open:\(a.name)"] }
        }
        for verb in quitVerbs where n.hasPrefix(verb + " ") {
            let target = squash(String(n.dropFirst(verb.count + 1)))
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            if let r = running.first(where: { squash($0.localizedName ?? "") == target }), let name = r.localizedName {
                return ["quit:\(name)"]
            }
        }
        return nil
    }

    /// "volume 30", "set volume to 30 percent" → 30 (rounded to the nearest 10).
    static func volumeLevel(_ n: String) -> Int? {
        guard let r = n.range(of: #"^(set )?volume (to )?(\d{1,3})( percent)?$"#, options: .regularExpression) else { return nil }
        let digits = n[r].split(separator: " ").first { Int($0) != nil }.flatMap { Int($0) }
        guard let v = digits, v <= 100 else { return nil }
        return Int((Double(v) / 10).rounded()) * 10
    }
}
