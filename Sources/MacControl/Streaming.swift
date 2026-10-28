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
    /// The last clause is a web search whose query may still be growing.
    var searching = false

    static let textMarker = #"(?i)(?:\b(?:that says|which says|saying|with the text|with text)\b|(?<=\b(?:it|title|heading|header|subject|name|note|line|message|text|body|this|that) )says?\b|(?:^|\band\s+|\bthen\s+|,\s*)(?:type|write|dictate)\b)[:,]?\s*"#
    static let searchMarker = #"(?i)\b(?:search(?: the web| google)?(?: for)?|google|look up)\b"#
    static let connector = #"(?i)\s*(?:[,;]|[.?!]\s+|\band then\b|\bthen\b|\band\b|\bafter that\b)\s*"#
    /// Talk around a command: "Okay, now can you …", "once you're there, …", "let's …", "… for me?".
    static let leadIn = #"(?i)^(?:(?:ok(?:ay)?|alright|all right|so|now|great|cool|nice|perfect|awesome|well|um+|uh+|hmm+|and|then|also|hey|yes|yeah|oh)\b[\s,.!]*)*(?:(?:once|when|now that) (?:you'?re|you are|it'?s|it is) (?:there|open|up)\b[\s,]*)?(?:(?:can|could|would|will) you(?: please)?(?: go ahead and)?\b|please\b|let'?s\b|let us\b|i (?:want|need|would like|'d like) (?:you )?to\b|go ahead and\b)?\s*"#
    /// "open Google Chrome", "switch to Google Docs": an app name, not a search.
    static let openBeforeSearch = #"(?i)\b(?:open|launch|start|quit|close|switch to|go to|show)(?: up)?(?: the)?\s*$"#
    static let tail = #"(?i)[\s,]*(?:for me|for us|please|real quick)?[\s?.!,]*$"#
    /// A clause ending in one of these is still waiting for its object ("open up", "switch to", "search for").
    static let unfinishedEndings: Set<String> = ["up", "to", "for", "in", "on", "into", "with", "of", "at", "from", "open", "go",
                                                 "switch", "launch", "start", "show", "make", "create", "new", "set", "turn", "and"]
    /// Words that on their own are conversation, not a command ("Great, great.", "Cool, awesome, thank you").
    static let chatterWords: Set<String> = [
        "ok", "okay", "alright", "all", "right", "great", "cool", "nice", "perfect", "awesome", "good", "thanks", "thank", "you",
        "so", "now", "um", "uh", "hmm", "yes", "yeah", "yep", "well", "wow", "sure", "got", "it", "that", "s", "is", "and",
        "then", "also", "hey", "oh", "amazing", "sweet", "excellent", "please", "the", "a", "my",
    ]
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
            let t = command[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " '\"“”‘’"))
            text = t.isEmpty ? nil : t.prefix(1).uppercased() + t.dropFirst()
            command = String(command[..<r.lowerBound])
        }
        // A search swallows the rest of the command, so "search for salt and pepper" stays one clause.
        var search: String?
        if let r = command.range(of: searchMarker, options: .regularExpression),
           command[..<r.lowerBound].range(of: openBeforeSearch, options: .regularExpression) == nil {
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
        return Utterance(clauses: clauses, text: text, complete: max(0, complete), searching: search != nil && !final)
    }

    /// The command inside a clause, without the talk around it: "Alright, can you open up Notes for me?" → "open up Notes".
    static func core(_ clause: String) -> String {
        var c = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        c = c.replacingOccurrences(of: leadIn, with: "", options: .regularExpression)
        c = c.replacingOccurrences(of: tail, with: "", options: .regularExpression)
        return c.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;!?"))
    }

    /// Nothing to act on: acknowledgements and filler ("Great, great.", "Okay.", "Thank you").
    static func isChatter(_ s: String) -> Bool {
        let words = core(s).lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined().split(separator: " ")
        return words.allSatisfy { chatterWords.contains(String($0)) }
    }

    /// What was said with the chatter clauses dropped ("Great. Open Safari." → "Open Safari"), or "" if that's all it was.
    /// Only chatter before the command, and after it unless text is being dictated, is dropped; the rest keeps its
    /// own wording, so a search for "salt and pepper" stays intact.
    static func dropChatter(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: connector) else { return s }
        var parts: [Range<String.Index>] = [], last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(last..<r.lowerBound); last = r.upperBound
        }
        parts.append(last..<s.endIndex)
        var lo = 0, hi = parts.count
        while lo < hi && isChatter(String(s[parts[lo]])) { lo += 1 }
        if s.range(of: textMarker, options: .regularExpression) == nil {
            while hi > lo && isChatter(String(s[parts[hi - 1]])) { hi -= 1 }
        }
        guard lo < hi else { return "" }
        return lo == 0 && hi == parts.count ? s : String(s[parts[lo].lowerBound..<parts[hi - 1].upperBound])
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
        let words = FastPath.normalize(core(clause)).split(separator: " ")
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
    /// The clause still being spoken: the words last decided on, and the action they gave. The same action from two
    /// successive transcripts means it's settled, and it runs before the sentence is over.
    var guessWords: String?
    var guess: String?
    /// The browser was brought forward as soon as a search started.
    var primedSearch = false
    /// Each clause handled before the end of the utterance: its words (normalized, squashed) and what it did ("none"
    /// when skipped). The final transcript is matched against these by content, not position.
    var ran: [(words: String, action: String)] = []
}

extension Controller {
    /// A live transcript while the key is held: run any newly finished clauses.
    func streamPartial(_ text: String) {
        guard listening, !typingMode, pending == nil else { return }
        // The previous command's last steps are still running; this one starts once they're out.
        if finishing { heldPartial = text; overlay.show(heard: text, picked: "", color: .systemRed, listening: true); return }
        guard prefs.actWhileTalking else { overlay.show(heard: text, picked: contextLine, color: .systemRed, listening: true); return }
        stream.latest = Utterance.parse(text, final: false)
        overlay.show(heard: text, picked: stream.actions.isEmpty ? contextLine : stream.actions.map { "✓ " + describe($0) }.joined(separator: "   "),
                     color: .systemRed, listening: true)
        pumpStream()
    }

    func pumpStream() {
        guard !stream.busy, !stream.frozen, let u = stream.latest else { return }
        if stream.done < u.complete {
            let clause = u.clauses[stream.done]
            // "Alright,", "Great, great." — nothing to do; carry on with the next clause.
            if Utterance.isChatter(clause) { stream.done += 1; stream.guess = nil; stream.guessWords = nil; pumpStream(); return }
            // Not phrased as a command (someone else talking nearby, "the weather today"): pass over it rather than
            // hold everything up; the end of the utterance still gets to decide it.
            if !Utterance.looksLikeCommand(clause) && FastPath.match(clause, apps: apps, macros: store.macros) == nil {
                log("stream: \"\(clause)\" isn't a command — passed over for now")
                stream.done += 1
                pumpStream()
                return
            }
            stream.busy = true
            resolve(clause: clause) { [weak self] action, conf, source in
                guard let self else { return }
                // Not an action at all ("let's make the title"): skip it rather than stop.
                if action == "none" {
                    log("stream: \"\(clause)\" → nothing to do, skipped")
                    if (conf ?? 0) >= 0.5 { self.stream.ran.append((Controller.words(clause), "none")) }
                    self.stream.done += 1
                    self.streamIdle()
                    return
                }
                // Early, only what is clearly meant and harmless; anything else waits for the end of the sentence.
                let sure = source == "local" || (conf ?? 0) >= max(0.6, self.prefs.pickerThreshold)
                guard let action, action != "none", sure, !Controller.isDestructive(action) else {
                    self.stream.frozen = true
                    self.streamIdle()
                    return
                }
                log("stream: \"\(clause)\" → \(action) while still talking")
                self.runStreamStep(action, conf: conf, clause: clause) { self.streamIdle() }
            }
            return
        }
        // The clause still being spoken: run it as soon as it's unambiguous, without waiting for "and" or a pause.
        guard stream.done == u.complete, stream.done < u.clauses.count else { return }
        let clause = u.clauses[stream.done]
        if u.searching { primeSearch(); return }   // the query is still coming
        let words = FastPath.normalize(Utterance.core(clause))
        let list = words.split(separator: " ")
        // "open up", "switch to": the thing to act on hasn't been said yet.
        guard list.count >= 2, !Utterance.unfinishedEndings.contains(String(list.last!)), Utterance.looksLikeCommand(clause) else { return }
        stream.busy = true
        // An exact phrase is free to check on every transcript.
        if let a = FastPath.match(clause, apps: apps, macros: store.macros), a.count == 1 {
            settleGuess(a[0], conf: 1, source: "local", clause: clause, words: words, at: u.complete)
            return
        }
        // One decision per new word, and only once there's enough to go on.
        guard words != stream.guessWords, list.count >= 3 else { stream.busy = false; return }
        stream.guessWords = words
        resolve(clause: clause) { [weak self] action, conf, source in
            self?.settleGuess(action, conf: conf, source: source, clause: clause, words: words, at: u.complete)
        }
    }

    /// Runs a decision on the clause still being spoken once it's settled: harmless, confident, nothing longer it
    /// could still turn into, and either an exact phrase or the same answer the previous transcript gave. Values that
    /// carry a number ("volume=4" on the way to "volume=40") or still need the rest of the sentence never run early.
    func settleGuess(_ action: String?, conf: Double?, source: String, clause: String, words: String, at index: Int) {
        let sure = source == "local" || (conf ?? 0) >= 0.75
        guard let action, action != "none", sure, !Controller.isDestructive(action), !action.contains("="),
              action != "browser:search", stream.done == index, !couldGrow(action, words: words) else {
            stream.guess = nil
            streamIdle()
            return
        }
        let settled = source == "local" || stream.guess == action
        guard settled else { stream.guess = action; streamIdle(); return }
        log("stream: \"\(clause)\" → \(action) before the clause was finished")
        runStreamStep(action, conf: conf, clause: clause) { self.streamIdle() }
    }

    /// What's been said could still become something else: "open Notes" → "open Notesnook" (another app's name
    /// starts with this one's), "dark mode" → "dark mode off", "open github.co" → "….com".
    func couldGrow(_ action: String, words: String) -> Bool {
        if action.hasPrefix("url:") { return true }
        if FastPath.phrases.keys.contains(where: { $0.hasPrefix(words + " ") })
            || store.macros.contains(where: { FastPath.normalize($0.phrase).hasPrefix(words + " ") }) { return true }
        guard action.hasPrefix("open:") else { return false }
        let name = FastPath.squash(String(action.dropFirst(5)))
        return apps.contains { app in
            let n = FastPath.squash(app.name)
            return n.count > name.count && n.hasPrefix(name)
        }
    }

    /// A search has started: bring the browser forward now, so only the query is left when it's finished.
    func primeSearch() {
        guard !stream.primedSearch else { return }
        stream.primedSearch = true
        if let (app, _) = browserTarget() {
            if !app.isActive { app.activate() }
        } else if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.google.com")!) {
            NSWorkspace.shared.openApplication(at: browser, configuration: NSWorkspace.OpenConfiguration())
        }
        log("stream: search started — browser brought forward")
    }

    func streamIdle() {
        stream.busy = false
        if let idle = stream.onIdle { stream.onIdle = nil; idle() } else if listening && !finishing { pumpStream() }
    }

    func runStreamStep(_ action: String, conf: Double?, clause: String, then: @escaping () -> Void) {
        if stream.done == 0 && stream.actions.isEmpty { undoSteps = [] }
        lastHeard = clause
        stream.guess = nil; stream.guessWords = nil
        stream.ran.append((Controller.words(clause), action))
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
            if action.hasPrefix("browser:") || action.hasPrefix("url:") || self.stream.primedSearch,
               let (browser, _) = self.browserTarget() { self.stream.intended = browser }
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
            let input = "User said: \"\(clause)\"\nFrontmost app: \(self.targetApp?.localizedName ?? "unknown")" + self.recentContext
            client.decide(input: input, choices: self.buildChoices(for: clause)) { res in
                self.credits.record(res)
                self.refreshCredits()
                done(res.steps.first?.choice, res.steps.first?.confidence, "api")
            }
        } } }
    }

    /// A clause's words for matching against what already ran: normalized, without the talk around it, no spaces.
    static func words(_ clause: String) -> String { FastPath.squash(Utterance.core(clause)) }

    /// At the end of an utterance: run whatever wasn't run early, then type any dictated text. The final transcript is
    /// matched to what already ran by its words, not by position — it may punctuate differently ("Okay open Safari"
    /// → "Okay, open Safari, new tab"), or a clause may have grown after it ran ("open Notes in a new window"), in
    /// which case it's decided again and runs only if that gives something different.
    func finishUtterance(_ heard: String, turn: Int? = nil) {
        let t = turn ?? self.turn
        if stream.busy {
            stream.onIdle = { [weak self] in self?.finishUtterance(heard, turn: t) }
            return
        }
        let u = Utterance.parse(heard, final: true)
        let remaining = Controller.remaining(u.clauses, ran: stream.ran)
        overlay.show(heard: "“\(heard)”", picked: remaining.isEmpty && u.text == nil ? "" : "Finishing…", color: .systemBlue)
        runClauses(remaining, at: 0, text: u.text, heard: heard, turn: t)
    }

    /// The final clauses still to run, each with what it already did if it ran early under fewer words.
    static func remaining(_ clauses: [String], ran: [(words: String, action: String)]) -> [(clause: String, ran: String?)] {
        var left = ran[...]
        var out: [(clause: String, ran: String?)] = []
        for c in clauses where !Utterance.isChatter(c) {
            let w = words(c)
            if let j = left.firstIndex(where: { w == $0.words || (!$0.words.isEmpty && w.hasPrefix($0.words)) }) {
                let done = left[j]
                left = left[left.index(after: j)...]
                if w != done.words { out.append((c, done.action)) }
                continue
            }
            out.append((c, nil))
        }
        return out
    }

    func runClauses(_ clauses: [(clause: String, ran: String?)], at i: Int, text: String?, heard: String, turn t: Int) {
        if let blocked = stream.blockedBy {
            overlay.show(heard: "“\(heard)”", picked: "Stopped: \(blocked)", meta: stream.actions.map(describe).joined(separator: " → "),
                         color: .systemOrange, autoHide: 4)
            Sounds.failure()
            record(heard: heard, actions: stream.actions, ctx: streamContext(heard), ok: false, note: "Stopped: \(blocked)")
            turnDone(t)
            return
        }
        guard i < clauses.count else {
            guard let text else { finishStreamOverlay(heard, text: nil); turnDone(t); return }
            if holding { overlay.show(heard: "“\(heard)”", picked: "Let go of \(prefs.hotkey.title) to type it", color: .systemBlue) }
            typeDictated(text) { [weak self] typed in
                guard let self else { return }
                if typed { self.finishStreamOverlay(heard, text: text) }
                else { self.record(heard: heard, actions: self.stream.actions, ctx: self.streamContext(heard), ok: false, note: "Stopped: \(self.stream.blockedBy ?? "didn't type")") }
                self.turnDone(t)
            }
            return
        }
        let (clause, ranBefore) = clauses[i]
        let next = { [weak self] in self?.runClauses(clauses, at: i + 1, text: text, heard: heard, turn: t) }
        resolve(clause: clause) { [weak self] action, conf, source in
            guard let self else { return }
            // It grew after running early, but means the same thing: already done.
            if let ranBefore, action == ranBefore || action == "none" { next(); return }
            guard let action, action != "none", (conf ?? 0) >= 0.35 else {
                // Nothing to do for this part ("let's make the title" before what to type): go on with the rest.
                if action == "none" { next(); return }
                self.overlay.show(heard: "“\(heard)”", picked: "Not sure what “\(clause)” meant — stopped there",
                                  meta: self.stream.actions.map(self.describe).joined(separator: " → "), color: .systemGray, autoHide: 3)
                if !self.handsFree { Sounds.failure() }
                self.record(heard: heard, actions: self.stream.actions, ctx: self.streamContext(heard), ok: false, note: "Stopped at “\(clause)”")
                self.turnDone(t)
                return
            }
            if Controller.isDestructive(action) && source != "local" && (conf ?? 0) < self.prefs.confirmThreshold {
                self.askConfirm([action], ExecContext(heard: clause, source: "api", confidences: [conf], sttMs: nil, decideMs: nil, tokens: 0))
                self.turnDone(t)
                return
            }
            self.runStreamStep(action, conf: conf, clause: clause) { next() }
        }
    }

    /// Types only into the app the previous steps were aimed at; if focus moved elsewhere, says so instead.
    /// Calls back with whether it typed.
    func typeDictated(_ text: String, then done: @escaping (Bool) -> Void = { _ in }) {
        let intended = stream.intended
        // Still holding the hotkey (the sentence ended on a pause): type once it's let go.
        waitForModifiersUp(until: Date().addingTimeInterval(holding ? 30 : 1.5)) { [weak self] in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication
            guard let intended, front?.processIdentifier == intended.processIdentifier else {
                defer { done(false) }
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
            done(true)
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
