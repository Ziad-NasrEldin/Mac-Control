// Acting while you're still talking: finished clauses ("open the notes app and …") run as soon as they're heard,
// and "… that says hello" types the dictated text after the steps before it.
import AppKit

/// A spoken command split into its parts.
struct Utterance {
    /// Command clauses in the order spoken.
    var clauses: [String]
    /// Text to type after the clauses ("… that says <text>", "type <text>").
    var text: String?
    /// How many leading clauses are finished, so they're safe to run while the user keeps talking.
    var complete: Int

    static let textMarker = #"(?i)(?:\b(?:that says|which says|saying|with the text|with text)\b|(?:^|\band\s+|\bthen\s+|,\s*)(?:type|write|dictate)\b)[:,]?\s*"#
    static let searchMarker = #"(?i)\b(?:search(?: the web| google)?(?: for)?|google|look up)\b"#
    static let connector = #"(?i)\s*(?:[,;]|\.\s+|\band then\b|\bthen\b|\band\b|\bafter that\b)\s*"#
    static let verbs: Set<String> = [
        "open", "launch", "start", "switch", "go", "show", "quit", "close", "exit", "kill", "create", "make", "new", "add",
        "set", "turn", "move", "snap", "put", "tile", "maximize", "minimize", "center", "fill", "click", "press", "tap",
        "select", "choose", "search", "google", "look", "play", "pause", "resume", "skip", "next", "previous", "mute",
        "unmute", "lock", "take", "scroll", "reload", "refresh", "reopen", "undo", "run", "hide", "save", "export", "print",
        "copy", "paste", "delete", "rename", "format", "zoom", "enable", "disable", "dark", "light", "volume", "brightness",
        "louder", "quieter", "brighter", "dimmer", "full", "send", "reply", "duplicate", "bring", "use",
    ]

    static func parse(_ raw: String, final: Bool) -> Utterance {
        var command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String?
        if let r = command.range(of: textMarker, options: .regularExpression) {
            let t = command[r.upperBound...].trimmingCharacters(in: .whitespaces)
            text = t.isEmpty ? nil : t.prefix(1).uppercased() + t.dropFirst()
            command = String(command[..<r.lowerBound])
        }
        // A search swallows the rest of the command, so "search for salt and pepper" stays one clause.
        var search: String?
        if let r = command.range(of: searchMarker, options: .regularExpression) {
            search = String(command[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
            command = String(command[..<r.lowerBound])
        }
        let endsWithConnector = command.range(of: connector + "$", options: .regularExpression) != nil
        var clauses = split(command)
        if let search, !search.isEmpty { clauses.append(search) }

        let complete: Int
        if final { complete = clauses.count }
        else if search != nil { complete = clauses.count - 1 }   // the query may still be growing
        else if text != nil || endsWithConnector { complete = clauses.count }
        else { complete = clauses.count - 1 }                     // the last clause may still be growing
        return Utterance(clauses: clauses, text: text, complete: max(0, complete))
    }

    static func split(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: connector) else { return [s] }
        var out: [String] = [], last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound])); last = r.upperBound
        }
        out.append(String(s[last...]))
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,;!?")) }.filter { !$0.isEmpty }
    }

    /// Whether a clause reads like an instruction (gates running it before the user has finished).
    static func looksLikeCommand(_ clause: String) -> Bool {
        let words = FastPath.normalize(clause).split(separator: " ")
        guard let first = words.first else { return false }
        return verbs.contains(String(first)) || (words.count > 1 && verbs.contains(String(words[1])))
    }
}

struct StreamState {
    var done = 0
    var actions: [String] = []
    var confidences: [Double?] = []
    var busy = false
    /// Stop running clauses early (something was unclear); the rest waits for release.
    var frozen = false
    var latest: Utterance?
    var firstActionAt: Date?
    var releasedAt: Date?
    var onIdle: (() -> Void)?
    /// Why the remaining steps were stopped (focus was taken by another app).
    var blockedBy: String?
    /// The app the command is aimed at: the one in front at key press, then whatever a step opened or switched to.
    /// If anything else comes to the front mid-command (a game, a notification app), the rest stops.
    var intended: NSRunningApplication?
}

extension Controller {
    /// A live transcript while the key is held: run any newly finished clauses.
    func streamPartial(_ text: String) {
        guard holding, !typingMode, pending == nil, prefs.actWhileTalking else { return }
        stream.latest = Utterance.parse(text, final: false)
        overlay.show(heard: text, picked: stream.actions.isEmpty ? contextLine : stream.actions.map { "✓ " + describe($0) }.joined(separator: "   "),
                     color: .systemRed, listening: true)
        pumpStream()
    }

    func pumpStream() {
        guard !stream.busy, !stream.frozen, let u = stream.latest, stream.done < u.complete else { return }
        let clause = u.clauses[stream.done]
        guard Utterance.looksLikeCommand(clause) else { stream.frozen = true; return }
        stream.busy = true
        resolve(clause: clause) { [weak self] action, conf, source in
            guard let self else { return }
            // Early, only what is clearly meant and harmless; anything else waits for the full sentence.
            let sure = source == "local" || (conf ?? 0) >= max(0.6, self.prefs.pickerThreshold)
            guard let action, action != "none", sure, !Controller.isDestructive(action) else {
                self.stream.frozen = true
                self.streamIdle()
                return
            }
            log("stream: \"\(clause)\" → \(action) while still talking")
            self.runStreamStep(action, conf: conf) { self.streamIdle() }
        }
    }

    func streamIdle() {
        stream.busy = false
        if let idle = stream.onIdle { stream.onIdle = nil; idle() } else if holding { pumpStream() }
    }

    func runStreamStep(_ action: String, conf: Double?, then: @escaping () -> Void) {
        if stream.done == 0 && stream.actions.isEmpty { undoSteps = [] }
        stream.done += 1
        stream.actions.append(action)
        stream.confidences.append(conf)
        if stream.firstActionAt == nil { stream.firstActionAt = Date() }
        if let u = captureUndo(action) { undoSteps.append(u) }
        perform(action)
        afterStep(action, then: then)
    }

    /// Lets an opened app come forward, then rereads the front app's menus and controls for the next clause.
    func afterStep(_ action: String, then: @escaping () -> Void) {
        let rescan = { [weak self] in
            guard let self else { return }
            if action.hasPrefix("browser:"), let (browser, _) = self.browserTarget() { self.stream.intended = browser }
            let front = NSWorkspace.shared.frontmostApplication
            if let intended = self.stream.intended, front?.processIdentifier != intended.processIdentifier, self.stream.blockedBy == nil {
                self.stream.frozen = true
                self.stream.blockedBy = "\(front?.localizedName ?? "another app") took focus from \(intended.localizedName ?? "the app")"
                log("stream: \(self.stream.blockedBy!) — stopping")
                then()
                return
            }
            self.retarget()
            guard let app = self.targetApp, app.processIdentifier != getpid() else { then(); return }
            let isBrowser = self.targetBrowser != nil
            uiQueue.async {
                enableManualAccessibility(app)
                let menus = collectMenuItems(app)
                let controls = isBrowser ? [] : collectWindowControls(app)
                DispatchQueue.main.async { self.menuItems = menus; self.windowControls = controls; then() }
            }
        }
        if action.hasPrefix("open:"), let entry = apps.first(where: { $0.name == String(action.dropFirst(5)) }) {
            waitForFrontmost(entry.url, until: Date().addingTimeInterval(4)) { [weak self] in
                guard let self else { return }
                // Another app grabbed focus (a game, a dialog): don't aim the next steps at the wrong window.
                if let front = NSWorkspace.shared.frontmostApplication, front.bundleURL?.standardizedFileURL == entry.url.standardizedFileURL {
                    self.stream.intended = front
                } else {
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
                    log("stream: \(entry.name) isn't in front (\(front) is); stopping")
                    self.stream.frozen = true
                    self.stream.blockedBy = "\(entry.name) didn't stay in front — \(front) took focus"
                }
                rescan()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: rescan)
        }
    }

    /// One clause → one action: exact phrase locally, otherwise a single-step decision.
    func resolve(clause: String, done: @escaping (String?, Double?, String) -> Void) {
        if let a = FastPath.match(clause, apps: apps, macros: store.macros), a.count == 1 { done(a[0], 1, "local"); return }
        guard let client else { done(nil, nil, "api"); return }
        scriptQueue.async { uiQueue.async { DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let input = "User said: \"\(clause)\"\nFrontmost app: \(self.targetApp?.localizedName ?? "unknown")"
            client.decide(input: input, choices: self.buildChoices(for: clause)) { res in
                self.credits.record(res)
                self.refreshCredits()
                done(res.steps.first?.choice, res.steps.first?.confidence, "api")
            }
        } } }
    }

    /// After release: finish whatever wasn't run early, then type any dictated text.
    func finishUtterance(_ heard: String) {
        if stream.busy {
            stream.onIdle = { [weak self] in self?.finishUtterance(heard) }
            return
        }
        let u = Utterance.parse(heard, final: true)
        let remaining = Array(u.clauses.dropFirst(stream.done))
        overlay.show(heard: "“\(heard)”", picked: remaining.isEmpty && u.text == nil ? "" : "Finishing…", color: .systemBlue)
        runClauses(remaining, at: 0, text: u.text, heard: heard)
    }

    func runClauses(_ clauses: [String], at i: Int, text: String?, heard: String) {
        if let blocked = stream.blockedBy {
            overlay.show(heard: "“\(heard)”", picked: "Stopped: \(blocked)", meta: stream.actions.map(describe).joined(separator: " → "),
                         color: .systemOrange, autoHide: 4)
            Sounds.failure()
            record(heard: heard, actions: stream.actions, ctx: streamContext(heard), ok: false, note: "Stopped: \(blocked)")
            return
        }
        guard i < clauses.count else {
            if let text { typeDictated(text) }
            finishStreamOverlay(heard, text: text)
            return
        }
        resolve(clause: clauses[i]) { [weak self] action, conf, source in
            guard let self else { return }
            guard let action, action != "none", (conf ?? 0) >= 0.35 else {
                self.overlay.show(heard: "“\(heard)”", picked: "Not sure what “\(clauses[i])” meant — stopped there",
                                  meta: self.stream.actions.map(self.describe).joined(separator: " → "), color: .systemGray, autoHide: 3)
                Sounds.failure()
                self.record(heard: heard, actions: self.stream.actions, ctx: self.streamContext(heard), ok: false, note: "Stopped at “\(clauses[i])”")
                return
            }
            if Controller.isDestructive(action) && source != "local" && (conf ?? 0) < self.prefs.confirmThreshold {
                self.askConfirm([action], ExecContext(heard: clauses[i], source: "api", confidences: [conf], sttMs: nil, decideMs: nil, tokens: 0))
                return
            }
            self.runStreamStep(action, conf: conf) { self.runClauses(clauses, at: i + 1, text: text, heard: heard) }
        }
    }

    /// Types only into the app the previous steps were aimed at; if focus moved elsewhere, says so instead.
    func typeDictated(_ text: String) {
        let intended = stream.intended
        waitForModifiersUp(until: Date().addingTimeInterval(1.5)) { [weak self] in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication
            guard let intended, front?.processIdentifier == intended.processIdentifier else {
                self.stream.blockedBy = "didn't type — \(front?.localizedName ?? "another app") is in front, not \(intended?.localizedName ?? "the app you were talking to")"
                log("stream: \(self.stream.blockedBy!)")
                self.overlay.show(heard: "Didn't type", picked: self.stream.blockedBy!, color: .systemOrange, autoHide: 4)
                Sounds.failure()
                return
            }
            self.stream.actions.append("type:\(text)")
            if let app = front {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                let focused = axAttr(ax, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
                let window = axAttr(ax, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
                log("typing into \(app.localizedName ?? "?"): \(focused.flatMap { axString($0, kAXRoleAttribute) } ?? "no focus") in window \"\(window.flatMap { axString($0, kAXTitleAttribute) } ?? "?")\"")
            }
            typeText(text)
        }
    }

    func streamContext(_ heard: String) -> ExecContext {
        ExecContext(heard: heard, source: "stream", confidences: stream.confidences, sttMs: listener.lastSttMs, decideMs: nil, tokens: 0)
    }

    func finishStreamOverlay(_ heard: String, text: String?) {
        let names = stream.actions.map(describe)
        var meta = listener.lastSttMs.map { "speech \($0) ms" } ?? ""
        if let first = stream.firstActionAt, let released = stream.releasedAt, first < released {
            meta = "first action \(Int(released.timeIntervalSince(first) * 1000)) ms before you let go" + (meta.isEmpty ? "" : "  ·  " + meta)
        }
        overlay.show(heard: "“\(heard)”", picked: names.isEmpty ? "Nothing to do" : "→ " + names.joined(separator: "  →  "), meta: meta,
                     color: names.isEmpty ? .systemGray : .systemGreen, autoHide: 2.2 + 0.6 * Double(max(0, names.count - 1)))
        if !names.isEmpty { Sounds.success() }
        record(heard: heard, actions: stream.actions, ctx: streamContext(heard), ok: !names.isEmpty)
    }
}
