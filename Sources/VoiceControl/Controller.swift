import AppKit
import AVFoundation
import Speech
import ApplicationServices

// MARK: - App

/// What led to a set of actions, for the overlay and history.
struct ExecContext {
    let heard: String
    /// "local" (exact phrase), "api", or "picked" (chosen from the low-confidence picker).
    var source: String
    var confidences: [Double?]
    let sttMs: Int?
    let decideMs: Int?
    let tokens: Int
}

final class Controller: NSObject, NSApplicationDelegate {
    let overlay = Overlay()
    let listener = Listener()
    let prefs = Prefs.shared
    let store = Store.shared
    let credits = Credits()
    var client: DecisionClient?
    var apps: [AppEntry] = []
    var shortcuts: [String] = []
    var statusItem: NSStatusItem!
    let hotkeyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sttItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let creditItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    var holding = false
    var typingMode = false
    /// The current hotkey press answered a confirmation instead of starting to listen.
    var holdConsumed = false

    // Snapshot taken at key-down so it's ready when the user lets go.
    var targetApp: NSRunningApplication?
    var targetBrowser: BrowserKind?
    var pageElements: [PageElement] = []
    var pageTitle = ""
    var tabs: [BrowserTab] = []
    var menuItems: [UIAction] = []
    var windowControls: [UIAction] = []
    var lastHeard = ""
    let maxChainSteps = 3
    /// value → human description of every choice offered recently.
    var labels: [String: String] = [:]

    /// Reverses the last command's steps.
    var undoSteps: [UndoStep] = []

    enum Pending { case confirm([String], ExecContext), pick([String], ExecContext) }
    var pending: Pending?
    var pendingTimeout: DispatchWorkItem?

    // MARK: Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        refreshCredits()
        log("accessibility trusted: \(AXIsProcessTrusted())")
        rescan()
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.rescan() }
        listener.parakeet.onStatus = { [weak self] s in self?.sttItem.title = s }
        listener.parakeet.onReady = { [weak self] in self?.listener.parakeetBecameReady() }
        listener.onLevel = { [weak self] l in self?.overlay.level(l) }
        listener.onPartial = { [weak self] t in
            guard let self, self.holding else { return }
            self.overlay.show(heard: t.isEmpty ? "Listening…" : t, picked: self.contextLine, color: .systemRed, listening: true)
        }
        if let key = loadAPIKey(), !key.isEmpty { client = DecisionClient(key: key) }
        prefs.onChange = { [weak self] in self?.applyPrefs() }

        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            SelfTest(controller: self).run(CommandLine.arguments[i + 1])
            return
        }
        // Test hook: `VoiceControl --perform system:volume=50` runs one action without speech or the API.
        if let i = CommandLine.arguments.firstIndex(of: "--perform"), i + 1 < CommandLine.arguments.count {
            if let h = CommandLine.arguments.firstIndex(of: "--heard"), h + 1 < CommandLine.arguments.count { lastHeard = CommandLine.arguments[h + 1] }
            perform(CommandLine.arguments[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            return
        }

        applyPrefs()
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        SFSpeechRecognizer.requestAuthorization { s in log("speech auth status \(s.rawValue)") }
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("mic access \(ok)") }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e); return e }

        if client == nil || !AXIsProcessTrusted() || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            SettingsWindow.shared.show(self, tab: .setup)
        }
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice Control")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let menu = NSMenu()
        menu.addItem(hotkeyItem)
        menu.addItem(sttItem)
        menu.addItem(.separator())
        menu.addItem(creditItem)
        menu.addItem(withTitle: "Set Credit Balance…", action: #selector(askBalance), keyEquivalent: "")
        menu.addItem(withTitle: "Open OpenAI Billing", action: #selector(openBilling), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Command History…", action: #selector(openHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Undo Last Command", action: #selector(undoFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rescan Apps and Shortcuts", action: #selector(rescan), keyEquivalent: "")
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != nil && $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
        sttItem.title = listener.parakeet.status
    }

    func applyPrefs() {
        overlay.position = prefs.overlayPosition
        Sounds.enabled = prefs.sounds
        hotkeyItem.title = "Hold \(prefs.hotkey.title) and speak · add ⇧ to type"
        listener.parakeet.load(prefs.speechModel)
        listener.setAlwaysOn(prefs.keepMicReady)
    }

    func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, Keychain.write(k) else { return }
        client = DecisionClient(key: k)
        log("API key updated in Keychain")
    }

    @objc func rescan() {
        DispatchQueue.global().async { [weak self] in
            let s = listShortcuts()
            DispatchQueue.main.async { self?.shortcuts = s; log("shortcuts: \(s.count)") }
        }
        apps = scanApplications()
        listener.hints = apps.map(\.name)
        log("scanned \(apps.count) apps")
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func openBilling() { NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/billing/overview")!) }
    @objc func openSettings() { SettingsWindow.shared.show(self, tab: .general) }
    @objc func openHistory() { SettingsWindow.shared.show(self, tab: .history) }
    @objc func undoFromMenu() { performUndo() }

    func refreshCredits() {
        statusItem.button?.title = " " + credits.title
        statusItem.button?.contentTintColor = credits.exhausted ? .systemRed : nil
        creditItem.title = credits.detail
    }

    @objc func askBalance() {
        let alert = NSAlert()
        alert.messageText = "OpenAI credit balance"
        alert.informativeText = "Enter the balance shown on your OpenAI billing page. Voice Control subtracts what each command costs."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 10.00"
        if let b = credits.remaining { field.stringValue = String(format: "%.2f", b) }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let v = Double(field.stringValue.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) else { return }
        credits.setBalance(v)
        refreshCredits()
    }

    var contextLine: String {
        guard let a = targetApp else { return "" }
        return targetBrowser != nil ? "\(a.localizedName ?? "") · \(pageElements.count) links/buttons" : (a.localizedName ?? "")
    }

    // MARK: Hotkey

    /// Active while the hotkey is held. Adding Shift (at any point during the hold) switches to typing mode.
    /// A press while a confirmation is showing confirms it instead of listening.
    func flags(_ e: NSEvent) {
        let down = prefs.hotkey.isDown(e.modifierFlags)
        let shift = e.modifierFlags.contains(.shift)
        if down && !holding {
            holding = true
            if case .confirm = pending { holdConsumed = true; confirmPending(); return }
            typingMode = shift
            begin()
        } else if down && shift && !typingMode && !holdConsumed {
            typingMode = true
            showListening()
        } else if !down && holding {
            holding = false
            if holdConsumed { holdConsumed = false; return }
            end()
        }
    }

    func showListening() {
        if typingMode { overlay.show(heard: "Listening to type…", picked: targetApp?.localizedName ?? "", color: .systemPurple, listening: true) }
        else if case .pick = pending { overlay.show(heard: "Say the number…", color: .systemYellow, listening: true) }
        else { overlay.show(heard: "Listening…", picked: contextLine, color: .systemRed, listening: true) }
    }

    func begin() {
        if !typingMode { client?.warmUp() }
        Sounds.listen()
        if case .pick = pending {} else {
            targetApp = NSWorkspace.shared.frontmostApplication
            targetBrowser = targetApp?.bundleIdentifier.flatMap { browserBundleIDs[$0] }
            pageElements = []; pageTitle = ""; tabs = []; menuItems = []; windowControls = []
        }
        showListening()
        listener.start()
        guard !typingMode, pending == nil, let app = targetApp, app.processIdentifier != getpid() else { return }
        if let kind = targetBrowser {
            scriptQueue.async { [weak self] in
                let json = runJS(collectJS, app: app, kind: kind)
                let title = runJS("document.title", app: app, kind: kind) ?? ""
                let tabList = listTabs(app: app, kind: kind)
                let els = json.flatMap { try? JSONDecoder().decode([PageElement].self, from: Data($0.utf8)) } ?? []
                DispatchQueue.main.async { self?.pageElements = els; self?.pageTitle = title; self?.tabs = tabList }
            }
        }
        let isBrowser = targetBrowser != nil
        uiQueue.async { [weak self] in
            enableManualAccessibility(app)
            let start = Date()
            let menus = collectMenuItems(app)
            // Web pages are already covered by the page scan; native windows get their controls read.
            let controls = isBrowser ? [] : collectWindowControls(app)
            log("ui scan \(app.localizedName ?? "") menus=\(menus.count) controls=\(controls.count) in \(Int(Date().timeIntervalSince(start) * 1000))ms")
            DispatchQueue.main.async { self?.menuItems = menus; self?.windowControls = controls }
        }
    }

    func end() {
        let typing = typingMode
        listener.stop { [weak self] text in
            guard let self else { return }
            let heard = text.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty else {
                self.overlay.show(heard: "Didn't catch that", picked: self.listener.lastProblem ?? "", color: .systemGray, autoHide: 3)
                Sounds.failure()
                return
            }
            if typing { self.type(heard); return }
            self.handle(heard)
        }
    }

    /// Routes a transcript: picker answer → local exact match → Decisions API.
    func handle(_ heard: String) {
        lastHeard = heard
        if case .pick(let options, _) = pending {
            if let n = Controller.number(in: heard), n >= 1, n <= options.count { choosePick(n - 1); return }
            clearPending()
        }
        if let actions = FastPath.match(heard, apps: apps, macros: store.macros) {
            let ctx = ExecContext(heard: heard, source: "local", confidences: actions.map { _ in 1.0 },
                                  sttMs: listener.lastSttMs, decideMs: 0, tokens: 0)
            execute(actions, ctx)
            return
        }
        // Wait for the page and UI scans if they're still running, then decide.
        scriptQueue.async { uiQueue.async { DispatchQueue.main.async { self.decide(heard) } } }
    }

    static func number(in heard: String) -> Int? {
        let words = ["one": 1, "two": 2, "three": 3, "first": 1, "second": 2, "third": 3, "to": 2, "too": 2, "for": 4, "won": 1]
        for w in FastPath.normalize(heard).split(separator: " ").reversed() {
            if let n = Int(w) { return n }
            if let n = words[String(w)] { return n }
        }
        return nil
    }

    // MARK: Typing mode

    func type(_ text: String) {
        let meta = listener.lastSttMs.map { "speech \($0) ms  ·  no API call" } ?? "no API call"
        overlay.show(heard: "“\(text)”", picked: "Typed into \(targetApp?.localizedName ?? "the focused field")",
                     meta: meta, color: .systemPurple, autoHide: 2)
        log("typed \(text.count) chars into \(targetApp?.localizedName ?? "?")")
        store.add(HistoryEntry(date: Date(), heard: text, actions: [], labels: ["Typed into \(targetApp?.localizedName ?? "?")"],
                               confidence: nil, sttMs: listener.lastSttMs, decideMs: nil, source: "typed", tokens: 0, ok: true))
        // Let go of the hotkey's modifiers first so they don't turn the typed letters into shortcuts.
        waitForModifiersUp(until: Date().addingTimeInterval(1.5)) { typeText(text + " ") }
    }

    func waitForModifiersUp(until deadline: Date, then: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.command, .option, .shift, .control])
        if held.isEmpty || Date() > deadline { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.waitForModifiersUp(until: deadline, then: then) }
    }

    // MARK: Deciding

    static let browserChoices: [Choice] = [
        Choice(value: "browser:back", description: "Browser: go back to the previous page"),
        Choice(value: "browser:forward", description: "Browser: go forward"),
        Choice(value: "browser:reload", description: "Browser: reload / refresh the page"),
        Choice(value: "browser:newtab", description: "Browser: open a new tab"),
        Choice(value: "browser:closetab", description: "Browser: close the current tab"),
        Choice(value: "browser:reopentab", description: "Browser: reopen the last closed tab / undo close tab"),
        Choice(value: "browser:search", description: "Browser: search the web / google / look something up"),
        Choice(value: "browser:scrollup", description: "Browser: scroll the page up"),
        Choice(value: "browser:scrolldown", description: "Browser: scroll the page down"),
    ]

    /// The Decisions API accepts at most 255 options per question.
    static let maxChoices = 255

    /// How well `label` matches what was said: shared words, longer words weighing more.
    static func relevance(_ label: String, to heard: String) -> Double {
        let said = Set(FastPath.normalize(heard).split(separator: " ").map(String.init))
        guard !said.isEmpty else { return 0 }
        return FastPath.normalize(label).split(separator: " ").reduce(0) { score, w in
            let weight: Double = w.count < 8 ? Double(w.count) : 8
            return said.contains(String(w)) ? score + weight : score
        }
    }

    /// Stable choices first (their meanings go into the cached catalog), then this moment's apps, menus, controls,
    /// tabs and page — the ones closest to what was said, up to the API's option limit.
    func buildChoices(for heard: String = "") -> [Choice] {
        var c: [Choice] = []
        for a in apps { c.append(Choice(value: "open:\(a.name)", description: "Open or switch to \(a.name)", inCatalog: true)) }
        c += (systemChoices + windowChoices + Controller.browserChoices).map { Choice(value: $0.value, description: $0.description, inCatalog: true) }
        for name in shortcuts { c.append(Choice(value: "shortcut:\(name)", description: "Run the Shortcut \"\(name)\"", inCatalog: true)) }
        for (i, m) in store.macros.enumerated() {
            c.append(Choice(value: "macro:\(i)", description: "Run the user's macro \"\(m.phrase)\" (\(m.steps.joined(separator: ", ")))", inCatalog: true))
        }
        c.append(Choice(value: "undo", description: "Undo / revert the last voice command", inCatalog: true))
        c.append(Choice(value: "none", description: "None of these actions match what the user said", inCatalog: true))

        var dynamic: [Choice] = []
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for r in running {
            guard let n = r.localizedName, r.bundleIdentifier != Bundle.main.bundleIdentifier, n != "Finder" else { continue }
            dynamic.append(Choice(value: "quit:\(n)", description: "Quit \(n) (running)"))
        }
        for (i, m) in menuItems.enumerated() {
            dynamic.append(Choice(value: "menu:\(i)", description: "Menu command in \(targetApp?.localizedName ?? "the current app"): \(m.label)"))
        }
        for (i, u) in windowControls.enumerated() {
            dynamic.append(Choice(value: "ui:\(i)", description: "Click the \(u.role) \"\(u.label)\" in the current window"))
        }
        if targetBrowser != nil {
            for t in tabs {
                dynamic.append(Choice(value: "tab:\(t.window):\(t.index)", description: "Browser: switch to the open tab titled \"\(t.title.prefix(80))\""))
            }
            for el in pageElements {
                dynamic.append(Choice(value: "click:\(el.i)", description: "Click the \(el.k) labeled \"\(el.t)\" on the current page"))
            }
        }
        // Keep the dynamic options most related to what was said; ties keep their natural order.
        let room = max(0, Controller.maxChoices - c.count)
        if dynamic.count > room {
            let ranked = dynamic.enumerated().sorted { a, b in
                let ra = Controller.relevance(a.element.description, to: heard), rb = Controller.relevance(b.element.description, to: heard)
                return ra != rb ? ra > rb : a.offset < b.offset
            }
            log("options: kept \(room) of \(dynamic.count) menus/controls/tabs/links (limit \(Controller.maxChoices))")
            dynamic = ranked.prefix(room).sorted { $0.offset < $1.offset }.map(\.element)
        }
        c += dynamic
        // Never exceed the limit, even with an unusually long app list; keep "none" as the last option.
        if c.count > Controller.maxChoices {
            c = Array(c.filter { $0.value != "none" }.prefix(Controller.maxChoices - 1))
            c.append(Choice(value: "none", description: "None of these actions match what the user said", inCatalog: true))
        }
        for ch in c { labels[ch.value] = ch.description }
        return c
    }

    /// Human description of an action value.
    func describe(_ value: String) -> String {
        if let l = labels[value] { return l }
        if let c = (systemChoices + windowChoices + Controller.browserChoices).first(where: { $0.value == value }) { return c.description }
        if value.hasPrefix("open:") { return "Open \(value.dropFirst(5))" }
        if value.hasPrefix("quit:") { return "Quit \(value.dropFirst(5))" }
        if value.hasPrefix("shortcut:") { return "Run the Shortcut \"\(value.dropFirst(9))\"" }
        if value.hasPrefix("macro:"), let i = Int(value.dropFirst(6)), i < store.macros.count { return "Macro \"\(store.macros[i].phrase)\"" }
        if value == "undo" { return "Undo the last command" }
        return value
    }

    /// Cheap local check so single commands don't pay for extra steps.
    func looksChained(_ s: String) -> Bool {
        s.range(of: #"(?i)\b(and|then|after that|also)\b|,"#, options: .regularExpression) != nil
    }

    let localDecider = LocalDecider()

    func decide(_ heard: String) {
        let choices = buildChoices(for: heard)
        let steps = looksChained(heard) ? maxChainSteps : 1
        var input = "User said: \"\(heard)\"\nFrontmost app: \(targetApp?.localizedName ?? "unknown")"
        if !pageTitle.isEmpty { input += "\nCurrent page: \(pageTitle)" }
        let sttMs = listener.lastSttMs
        guard let client else {
            decideLocally(heard, input: input, choices: choices, steps: steps, sttMs: sttMs, because: "No OpenAI key")
            return
        }
        overlay.show(heard: "“\(heard)”", picked: "Deciding…", color: .systemBlue)
        client.decide(input: input, choices: choices, steps: steps) { [weak self] res in
            guard let self else { return }
            self.credits.record(res)
            self.refreshCredits()
            if let err = res.error {
                self.decideLocally(heard, input: input, choices: choices, steps: steps, sttMs: sttMs,
                                   because: res.errorCode == "insufficient_quota" || res.errorCode == "credit_balance_exhausted" ? "Out of OpenAI credits" : err)
                return
            }
            self.handleDecision(res, heard: heard, sttMs: sttMs, source: "api")
        }
    }

    /// The fallback: Perplexity's Decider running on this Mac. Slower (seconds), but free and offline.
    func decideLocally(_ heard: String, input: String, choices: [Choice], steps: Int, sttMs: Int?, because reason: String) {
        guard prefs.localFallback else {
            overlay.show(heard: "“\(heard)”", picked: "Error: \(reason)", color: .systemRed, autoHide: 4)
            Sounds.failure()
            record(heard: heard, actions: [], ctx: nil, ok: false, note: "Error: \(reason)")
            return
        }
        log("falling back to local Decider: \(reason)")
        overlay.show(heard: "“\(heard)”", picked: "OpenAI unavailable — asking the local Decider…", meta: reason, color: .systemBlue)
        localDecider.decide(heard: heard, input: input, choices: choices, steps: steps,
                            instructions: { DecisionClient.instructions(step: $0, of: steps, catalog: false) }) { [weak self] res in
            guard let self else { return }
            if let err = res.error {
                self.overlay.show(heard: "“\(heard)”", picked: "OpenAI: \(reason)\n\(err)", meta: "\(res.ms) ms", color: .systemRed, autoHide: 5)
                Sounds.failure()
                self.record(heard: heard, actions: [], ctx: nil, ok: false, note: "Both deciders failed")
                return
            }
            self.handleDecision(res, heard: heard, sttMs: sttMs, source: "local-ai")
        }
    }

    func handleDecision(_ result: DecisionResult, heard: String, sttMs: Int?, source: String) {
        // A step repeating an earlier one is a model slip ("mute" twice would undo itself); drop it.
        var res = result
        var seen = Set<String>()
        res.steps = res.steps.filter { seen.insert($0.choice).inserted }
        let ctx = ExecContext(heard: heard, source: source, confidences: res.steps.map(\.confidence),
                              sttMs: sttMs, decideMs: res.ms, tokens: res.inputTokens)
        guard !res.steps.isEmpty else {
            overlay.show(heard: "“\(heard)”", picked: "No matching action", meta: meta(ctx), color: .systemGray, autoHide: 2)
            Sounds.failure()
            record(heard: heard, actions: [], ctx: ctx, ok: false, note: "No matching action")
            return
        }
        if res.steps.count == 1, let conf = res.steps[0].confidence, conf < prefs.pickerThreshold {
            var options: [String] = []
            for v in [res.steps[0].choice] + res.alternatives.map(\.value) where !options.contains(v) { options.append(v) }
            if options.count >= 2 { showPicker(Array(options.prefix(3)), ctx); return }
        }
        execute(res.steps.map(\.choice), ctx)
    }

    func meta(_ ctx: ExecContext) -> String {
        let speech = ctx.sttMs.map { "  ·  speech \($0) ms" } ?? ""
        switch ctx.source {
        case "local": return "exact match  ·  no API call" + speech
        case "picked": return "you picked it" + speech
        case "local-ai":
            let conf = ctx.confidences.map { $0.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }.joined(separator: " / ")
            return "local Decider  ·  conf \(conf)  ·  \(ctx.decideMs ?? 0) ms" + speech
        default:
            let conf = ctx.confidences.map { $0.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }.joined(separator: " / ")
            return "conf \(conf)  ·  decide \(ctx.decideMs ?? 0) ms" + speech
        }
    }

    // MARK: Confirm and pick

    static func isDestructive(_ v: String) -> Bool {
        v.hasPrefix("quit:") || v.hasPrefix("shortcut:") || ["system:lock", "system:sleepdisplay", "window:close"].contains(v)
    }

    /// Asks first when a destructive step isn't certain (or always, if set); otherwise runs.
    func execute(_ actions: [String], _ ctx: ExecContext) {
        let unsure = actions.indices.contains { i in
            Controller.isDestructive(actions[i]) && (prefs.alwaysConfirm || (ctx.confidences[safe: i].flatMap { $0 } ?? 0) < prefs.confirmThreshold)
        }
        if unsure { askConfirm(actions, ctx) } else { runNow(actions, ctx) }
    }

    func runNow(_ actions: [String], _ ctx: ExecContext) {
        let names = actions.map(describe)
        overlay.show(heard: "“\(ctx.heard)”", picked: "→ " + names.joined(separator: "  →  "), meta: meta(ctx),
                     color: .systemGreen, autoHide: 2.2 + 0.8 * Double(actions.count - 1))
        Sounds.success()
        record(heard: ctx.heard, actions: actions, ctx: ctx, ok: true)
        run(actions, at: 0)
    }

    func askConfirm(_ actions: [String], _ ctx: ExecContext) {
        clearPending()
        pending = .confirm(actions, ctx)
        overlay.show(heard: "“\(ctx.heard)”", picked: actions.map(describe).joined(separator: "  →  ") + "?",
                     meta: "Return or \(prefs.hotkey.title) to confirm  ·  Esc to cancel", color: .systemOrange)
        Sounds.ask()
        KeyCatcher.shared.start { [weak self] code in
            switch code {
            case KeyCatcher.returnKey, KeyCatcher.enter: DispatchQueue.main.async { self?.confirmPending() }; return true
            case KeyCatcher.escape: DispatchQueue.main.async { self?.cancelPending("Cancelled") }; return true
            default: return false
            }
        }
        armTimeout(6)
    }

    func confirmPending() {
        guard case .confirm(let actions, let ctx) = pending else { return }
        clearPending()
        runNow(actions, ctx)
    }

    func showPicker(_ options: [String], _ ctx: ExecContext) {
        clearPending()
        pending = .pick(options, ctx)
        let lines = options.enumerated().map { "\($0.offset + 1)   \(describe($0.element))" }.joined(separator: "\n")
        overlay.show(heard: "“\(ctx.heard)” — which one?", picked: lines,
                     meta: "Press 1–\(options.count) or hold \(prefs.hotkey.title) and say the number  ·  Esc cancels",
                     color: .systemYellow)
        Sounds.ask()
        let keys = [KeyCatcher.one, KeyCatcher.two, KeyCatcher.three]
        KeyCatcher.shared.start { [weak self] code in
            if let i = keys.firstIndex(of: code), i < options.count { DispatchQueue.main.async { self?.choosePick(i) }; return true }
            if code == KeyCatcher.escape { DispatchQueue.main.async { self?.cancelPending("Cancelled") }; return true }
            return false
        }
        armTimeout(8)
    }

    func choosePick(_ i: Int) {
        guard case .pick(let options, var ctx) = pending, i < options.count else { return }
        clearPending()
        ctx.source = "picked"
        ctx.confidences = [1]
        runNow([options[i]], ctx)
    }

    func armTimeout(_ seconds: Double) {
        let w = DispatchWorkItem { [weak self] in self?.cancelPending("Timed out") }
        pendingTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func clearPending() {
        pending = nil
        pendingTimeout?.cancel(); pendingTimeout = nil
        KeyCatcher.shared.stop()
    }

    func cancelPending(_ why: String) {
        guard pending != nil else { return }
        clearPending()
        overlay.show(heard: why, color: .systemGray, autoHide: 1.2)
    }

    func record(heard: String, actions: [String], ctx: ExecContext?, ok: Bool, note: String? = nil) {
        store.add(HistoryEntry(date: Date(), heard: heard, actions: actions, labels: note.map { [$0] } ?? actions.map(describe),
                               confidence: ctx?.confidences.first.flatMap { $0 }, sttMs: ctx?.sttMs ?? listener.lastSttMs,
                               decideMs: ctx?.decideMs, source: ctx?.source ?? "api", tokens: ctx?.tokens ?? 0, ok: ok))
    }

    // MARK: Running actions

    /// Runs chained actions in order, waiting for an app to come to the front before the next step.
    func run(_ actions: [String], at i: Int) {
        guard i < actions.count else { return }
        let value = actions[i]
        if value == "undo" {
            performUndo()
        } else {
            if i == 0 || actions[..<i].allSatisfy({ $0 == "undo" }) { undoSteps = [] }
            if let u = captureUndo(value) { undoSteps.append(u) }
            perform(value)
        }
        guard i + 1 < actions.count else { return }
        let next = { [weak self] in self?.retarget(); self?.run(actions, at: i + 1) }
        if value.hasPrefix("open:"), let entry = apps.first(where: { $0.name == String(value.dropFirst(5)) }) {
            waitForFrontmost(entry.url, until: Date().addingTimeInterval(4), then: next)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: next)
        }
    }

    func waitForFrontmost(_ url: URL, until deadline: Date, then: @escaping () -> Void) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL
        if front == url.standardizedFileURL || Date() > deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then) // let its window appear
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForFrontmost(url, until: deadline, then: then) }
    }

    /// After a step changes the front app, later steps act on the new one.
    func retarget() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != targetApp?.processIdentifier else { return }
        targetApp = front
        targetBrowser = front?.bundleIdentifier.flatMap { browserBundleIDs[$0] }
        pageElements = []; tabs = []; menuItems = []; windowControls = []
    }

    func failed(_ msg: String) {
        overlay.show(heard: "Couldn't do that", picked: msg, color: .systemOrange, autoHide: 4)
        Sounds.failure()
    }

    func perform(_ value: String) {
        if value == "undo" { performUndo(); return }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (kind, arg) = (parts[0], parts[1])
        switch kind {
        case "open":
            if let a = apps.first(where: { $0.name == arg }) {
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                NSWorkspace.shared.openApplication(at: a.url, configuration: cfg)
            }
        case "quit":
            NSWorkspace.shared.runningApplications.first { $0.localizedName == arg }?.terminate()
        case "browser":
            browserCommand(arg)
        case "system":
            performSystem(arg) { [weak self] msg in self?.failed(msg) }
        case "window":
            performWindow(arg, app: targetApp ?? NSWorkspace.shared.frontmostApplication) { [weak self] msg in self?.failed(msg) }
        case "menu", "ui":
            let list = kind == "menu" ? menuItems : windowControls
            guard let i = Int(arg), i < list.count else { failed("That control is gone"); return }
            if !press(list[i].element) { failed("Couldn't press \(list[i].label)") }
        case "shortcut":
            scriptQueue.async { [weak self] in
                if let e = runShortcut(arg) { DispatchQueue.main.async { self?.failed(e) } }
            }
        case "macro":
            guard let i = Int(arg), i < store.macros.count else { return }
            resolve(store.macros[i].steps) { [weak self] actions in self?.run(actions, at: 0) }
        case "tab":
            let wt = arg.split(separator: ":").compactMap { Int($0) }
            guard wt.count == 2, let (app, k) = browserTarget() else { return }
            scriptQueue.async { switchTab(app: app, kind: k, window: wt[0], tab: wt[1]) }
        case "click":
            guard let app = targetApp, let k = targetBrowser else { return }
            let js = "(()=>{const e=document.querySelector('[data-vc=\"\(arg)\"]');if(!e)return 'missing';e.scrollIntoView({block:'center'});e.focus();e.click();return 'ok'})()"
            scriptQueue.async { _ = runJS(js, app: app, kind: k) }
        default: break
        }
    }

    /// Turns a macro's spoken steps into actions: exact phrases locally, anything else through the API.
    func resolve(_ steps: [String], done: @escaping ([String]) -> Void) {
        var out: [String] = []
        func next(_ i: Int) {
            guard i < steps.count else { done(out); return }
            if let a = FastPath.match(steps[i], apps: apps, macros: []) { out += a; next(i + 1); return }
            guard let client else { next(i + 1); return }
            client.decide(input: "User said: \"\(steps[i])\"", choices: buildChoices(for: steps[i])) { [weak self] res in
                self?.credits.record(res)
                out += res.steps.map(\.choice).filter { !$0.hasPrefix("macro:") }
                next(i + 1)
            }
        }
        next(0)
    }

    /// The browser to act on: the one in front, else any running browser.
    func browserTarget() -> (NSRunningApplication, BrowserKind)? {
        if let a = targetApp, let k = targetBrowser { return (a, k) }
        let candidates = [NSWorkspace.shared.frontmostApplication].compactMap { $0 } + NSWorkspace.shared.runningApplications
        for r in candidates { if let k = r.bundleIdentifier.flatMap({ browserBundleIDs[$0] }) { return (r, k) } }
        return nil
    }

    func browserCommand(_ cmd: String) {
        if cmd == "search" {
            let q = searchQuery(from: lastHeard)
            var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=?#")
            guard !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "https://www.google.com/search?q=\(enc)") else { failed("Didn't hear what to search for"); return }
            log("search \"\(q)\"")
            if let (app, _) = browserTarget(), let appURL = app.bundleURL {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let (app, kind) = browserTarget() else { failed("No browser is open"); return }
        // Give a browser that wasn't in front a moment to take keyboard focus.
        let delay = app.isActive ? 0 : 0.3
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            switch cmd {
            case "back": sendKey(33, flags: .maskCommand)                        // ⌘[
            case "forward": sendKey(30, flags: .maskCommand)                     // ⌘]
            case "reload": sendKey(15, flags: .maskCommand)                      // ⌘R
            case "newtab": sendKey(17, flags: .maskCommand)                      // ⌘T
            case "closetab": sendKey(13, flags: .maskCommand)                    // ⌘W
            case "reopentab": sendKey(17, flags: [.maskCommand, .maskShift])     // ⇧⌘T
            case "scrollup", "scrolldown":
                let dir = cmd == "scrollup" ? "-" : ""
                let js = "window.scrollBy({top:\(dir)innerHeight*0.8,behavior:'smooth'});'ok'"
                scriptQueue.async {
                    if runJS(js, app: app, kind: kind) == nil {
                        DispatchQueue.main.async { sendKey(cmd == "scrollup" ? 116 : 121) } // Page Up / Page Down
                    }
                }
            default: break
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
