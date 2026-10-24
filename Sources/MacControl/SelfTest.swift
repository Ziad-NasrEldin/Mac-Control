// `MacControl --selftest <name>` drives real features against real apps and the API, logging TEST PASS/FAIL lines.
import AppKit
import AVFoundation

@MainActor
final class SelfTest {
    let c: Controller
    var passed = 0, failed = 0
    init(controller: Controller) { c = controller }

    func run(_ name: String) {
        Task { @MainActor in
            log("TEST begin \(name)")
            switch name {
            case "native": await native()
            case "shortcuts": await shortcuts()
            case "speech": await speech()
            case "fastpath": fastpath()
            case "caching": await caching()
            case "picker": await picker()
            case "confirm": await confirm()
            case "undo": await undo()
            case "mic": await mic()
            case "keychain": keychain()
            case "macros": await macros()
            case "typing": await typing()
            case "settings": await settings()
            case "limit": await limit()
            case "fallback": await fallback()
            default: check(false, "unknown test \(name)")
            }
            log("TEST end \(name): \(passed) passed, \(failed) failed")
            NSApp.terminate(nil)
        }
    }

    func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1 }
        log("TEST \(ok ? "PASS" : "FAIL") \(what)")
    }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Opens an app and waits until it's frontmost. Returns it and whether it was already running.
    func bringUp(_ path: String) async -> (NSRunningApplication?, Bool) {
        let url = URL(fileURLWithPath: path)
        let wasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        for _ in 0..<100 {
            if let f = NSWorkspace.shared.frontmostApplication, f.bundleURL?.standardizedFileURL == url.standardizedFileURL {
                await sleep(0.5)
                return (f, wasRunning)
            }
            await sleep(0.05)
        }
        return (nil, wasRunning)
    }

    /// Runs the real choice-building + Decisions call for `heard` with the controller's current snapshot.
    func decide(_ heard: String, steps: Int = 1) async -> DecisionResult? {
        guard let key = loadAPIKey() else { check(false, "API key available"); return nil }
        let client = DecisionClient(key: key)
        let choices = c.buildChoices(for: heard)
        let input = "User said: \"\(heard)\"\nFrontmost app: \(c.targetApp?.localizedName ?? "unknown")"
        return await withCheckedContinuation { cont in
            client.decide(input: input, choices: choices, steps: steps) { cont.resume(returning: $0) }
        }
    }

    func label(_ value: String?) -> String {
        guard let value else { return "nil" }
        let parts = value.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let i = Int(parts[1]) {
            if parts[0] == "menu", i < c.menuItems.count { return "menu \(c.menuItems[i].label)" }
            if parts[0] == "ui", i < c.windowControls.count { return "ui \(c.windowControls[i].label)" }
        }
        return value
    }

    // MARK: Tests

    func native() async {
        let (calc, wasRunning) = await bringUp("/System/Applications/Calculator.app")
        guard let calc else { check(false, "Calculator came to front"); return }
        c.targetApp = calc; c.targetBrowser = nil
        enableManualAccessibility(calc)

        let t0 = Date()
        c.menuItems = collectMenuItems(calc)
        c.windowControls = collectWindowControls(calc)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        check(c.menuItems.count > 10, "menu scan found \(c.menuItems.count) items in \(ms) ms")
        log("TEST info menus: \(c.menuItems.prefix(12).map(\.label).joined(separator: " | "))")
        check(c.windowControls.count > 10, "window scan found \(c.windowControls.count) controls")
        log("TEST info controls: \(c.windowControls.prefix(20).map { "\($0.role):\($0.label)" }.joined(separator: " | "))")

        // Menu command through the real decision pipeline.
        let before = focusedWindow(of: calc).flatMap(axFrame)
        let r = await decide("switch to scientific mode")
        let pick = r?.steps.first?.choice
        check(label(pick).contains("Scientific"), "\"switch to scientific mode\" → \(label(pick)) (\(r?.steps.first?.confidence ?? -1))")
        if let pick { c.perform(pick) }
        await sleep(0.8)
        let after = focusedWindow(of: calc).flatMap(axFrame)
        check(before != nil && after != nil && before!.size != after!.size, "Calculator window changed size \(before?.size ?? .zero) → \(after?.size ?? .zero)")
        if let basic = collectMenuItems(calc).first(where: { $0.label.hasSuffix("› Basic") }) { press(basic.element) }
        await sleep(0.6)

        // Window button through the real decision pipeline.
        c.menuItems = collectMenuItems(calc)
        c.windowControls = collectWindowControls(calc)
        let r2 = await decide("press seven")
        let pick2 = r2?.steps.first?.choice
        check(label(pick2) == "ui 7", "\"press seven\" → \(label(pick2)) (\(r2?.steps.first?.confidence ?? -1))")
        if let pick2 { c.perform(pick2) }
        await sleep(0.3)
        let display = collectDisplayText(calc)
        check(display.contains("7"), "Calculator display shows \(display)")
        if let clear = collectWindowControls(calc).first(where: { ["clear", "all clear", "c", "ac"].contains($0.label.lowercased()) }) {
            press(clear.element)
        }
        if !wasRunning { calc.terminate() }
    }

    func collectDisplayText(_ app: NSRunningApplication) -> String {
        guard let w = focusedWindow(of: app) else { return "" }
        var queue = [w], texts: [String] = []
        while !queue.isEmpty && texts.count < 20 {
            let el = queue.removeFirst()
            if axString(el, kAXRoleAttribute) == kAXStaticTextRole, let v = axAttr(el, kAXValueAttribute) as? String { texts.append(v) }
            queue += (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return texts.joined(separator: " ")
    }

    func shortcuts() async {
        let list = listShortcuts()
        check(!list.isEmpty, "listed \(list.count) shortcuts")
        c.shortcuts = list
        let err = await Task.detached { runShortcut("Mac Control self-test missing shortcut") }.value
        check(err != nil, "running a missing shortcut reports an error: \(err ?? "none")")
        c.targetApp = NSWorkspace.shared.frontmostApplication
        c.menuItems = []; c.windowControls = []
        if list.contains("Make QR Code") {
            let r = await decide("make a QR code")
            check(r?.steps.first?.choice == "shortcut:Make QR Code", "\"make a QR code\" → \(r?.steps.first?.choice ?? "nil") (\(r?.steps.first?.confidence ?? -1)) [not run]")
        }
    }

    // MARK: More tests

    func waitParakeet() async -> Bool {
        if !c.listener.parakeet.ready { c.listener.parakeet.load(.english) }
        for _ in 0..<600 { if c.listener.parakeet.ready { return true }; await sleep(0.1) }
        return false
    }

    /// Speaks `text` with the system voice into 16 kHz float samples.
    func synthesize(_ text: String) -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vc-selftest.wav")
        _ = runTool("/usr/bin/say", ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text])
        guard let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    }

    func speech() async {
        check(await waitParakeet(), "Parakeet loaded")
        for (phrase, expect) in [("Open Notes", "open notes"), ("Move this window to the other display", "move this window to the other display"),
                                 ("Set the volume to forty percent", "set the volume to 40 percent")] {
            let samples = synthesize(phrase)
            let (text, ms) = await withCheckedContinuation { cont in c.listener.transcribe(samples: samples) { cont.resume(returning: ($0, $1)) } }
            let got = FastPath.normalize(text)
            check(got == FastPath.normalize(expect) || got == FastPath.normalize(phrase), "Parakeet heard \"\(text)\" for \"\(phrase)\" in \(ms) ms")
        }
    }

    func fastpath() {
        c.rescan()
        let cases: [(String, String?)] = [
            ("Open Notes.", "open:Notes"), ("please open chat GPT", "open:ChatGPT"), ("Switch to Safari", "open:Safari"),
            ("Volume 40", "system:volume=40"), ("Set volume to 75%", "system:volume=80"), ("Louder.", "system:volumeup"),
            ("Maximize", "window:maximize"), ("Next display.", "window:nextdisplay"), ("New tab", "browser:newtab"),
            ("Undo that", "undo"), ("Dark mode", "system:darkon"), ("Quit Finder", "quit:Finder"),
            ("open notes and make a new tab", nil), ("what's the weather", nil), ("open nonexistent app xyz", nil),
        ]
        for (said, expect) in cases {
            let t0 = DispatchTime.now()
            let got = FastPath.match(said, apps: c.apps, macros: [])?.first
            let us = (DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1000
            check(got == expect, "fast path \"\(said)\" → \(got ?? "API") in \(us) µs")
        }
    }

    func caching() async {
        c.rescan(); await sleep(1.5)
        c.targetApp = NSWorkspace.shared.frontmostApplication; c.targetBrowser = nil
        c.menuItems = []; c.windowControls = []
        let r1 = await decide("put the volume at forty")
        let r2 = await decide("make the screen brighter")
        check(r1?.steps.first?.choice == "system:volume=40", "catalog request → \(r1?.steps.first?.choice ?? "nil") in \(r1?.ms ?? -1) ms, \(r1?.inputTokens ?? 0) tokens")
        check(r2?.steps.first?.choice == "system:brightnessup", "second request → \(r2?.steps.first?.choice ?? "nil") in \(r2?.ms ?? -1) ms")
        check((r2?.cachedTokens ?? 0) > 1000, "second request used the cache: \(r2?.cachedTokens ?? 0) of \(r2?.inputTokens ?? 0) tokens cached")
    }

    func postKey(_ code: CGKeyCode) {
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
    }

    func picker() async {
        guard let saved = currentVolume() else { check(false, "read volume"); return }
        let ctx = ExecContext(heard: "volume something", source: "api", confidences: [0.3], sttMs: nil, decideMs: 1, tokens: 0)
        c.showPicker(["system:volume=30", "system:volume=40", "system:volume=50"], ctx)
        check(KeyCatcher.shared.isActive, "picker listens for 1–3 keys")
        log("TEST info overlay: \(c.overlay.current.heard) | \(c.overlay.current.picked.replacingOccurrences(of: "\n", with: " / "))")
        postKey(19) // "2"
        await sleep(0.8)
        check(currentVolume()?.level == 40, "pressing 2 picked option 2 (volume now \(currentVolume()?.level ?? -1))")
        check(c.pending == nil && !KeyCatcher.shared.isActive, "picker closed and released the keys")
        // Answering by voice.
        c.showPicker(["system:volume=30", "system:volume=60"], ctx)
        c.handle("number one")
        await sleep(0.6)
        check(currentVolume()?.level == 30, "saying \"number one\" picked option 1 (volume now \(currentVolume()?.level ?? -1))")
        runAppleScript("set volume output volume \(saved.level)\nset volume \(saved.muted ? "with" : "without") output muted")
    }

    func confirm() async {
        let (calc, _) = await bringUp("/System/Applications/Calculator.app")
        guard calc != nil else { check(false, "Calculator opened"); return }
        let unsure = ExecContext(heard: "close the calculator", source: "api", confidences: [0.55], sttMs: nil, decideMs: 1, tokens: 0)
        c.execute(["quit:Calculator"], unsure)
        check({ if case .confirm = c.pending { return true }; return false }(), "unsure quit asks first: \(c.overlay.current.picked)")
        postKey(53) // Esc
        await sleep(0.6)
        check(c.pending == nil && NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Calculator" }, "Esc cancelled, Calculator still running")
        c.execute(["quit:Calculator"], unsure)
        postKey(36) // Return
        await sleep(1.5)
        check(!NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Calculator" }, "Return confirmed, Calculator quit")
        let sure = ExecContext(heard: "lock", source: "local", confidences: [1.0], sttMs: nil, decideMs: 0, tokens: 0)
        check(!Controller.isDestructive("system:volume=30") && Controller.isDestructive("system:lock") && sure.confidences[0]! >= Prefs.shared.confirmThreshold,
              "exact phrases skip the question; risky list = quit, lock, sleep display, close window, Shortcuts")
    }

    func undo() async {
        guard let saved = currentVolume() else { check(false, "read volume"); return }
        c.run(["system:volume=20"], at: 0)
        await sleep(0.5)
        c.run(["undo"], at: 0)
        await sleep(0.5)
        check(currentVolume()?.level == saved.level, "undo restored volume \(saved.level) (now \(currentVolume()?.level ?? -1))")

        let wasRunning = NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Chess" }
        c.targetApp = NSWorkspace.shared.frontmostApplication
        c.run(["open:Chess"], at: 0)
        for _ in 0..<60 { if NSWorkspace.shared.frontmostApplication?.localizedName == "Chess" { break }; await sleep(0.1) }
        await sleep(1.0)
        if let chess = NSWorkspace.shared.frontmostApplication, chess.localizedName == "Chess", let w = focusedWindow(of: chess), let before = axFrame(w) {
            c.targetApp = chess
            let r = await decide("snap this to the left half")
            let pick = r?.steps.first?.choice ?? "window:left"
            c.undoSteps = []
            c.run([pick], at: 0)
            await sleep(0.8)
            let moved = axFrame(w)
            c.run(["undo"], at: 0)
            await sleep(1.2)
            let back = axFrame(w)
            check(moved != before && back == before, "\"\(pick)\" moved Chess \(before) → \(moved.map { "\($0)" } ?? "?"), undo put it back \(back.map { "\($0)" } ?? "?")")
        } else { check(false, "Chess window available") }
        if !wasRunning {
            c.undoSteps = []
            c.run(["open:Chess"], at: 0)   // already running now: undo = switch back
            c.run(["undo"], at: 0)
            NSWorkspace.shared.runningApplications.first { $0.localizedName == "Chess" }?.terminate()
            await sleep(0.8)
            check(!NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Chess" }, "cleaned up Chess")
        }
    }

    func mic() async {
        guard await waitParakeet() else { check(false, "Parakeet loaded"); return }
        // Cold start: mic opens on key press.
        c.listener.setAlwaysOn(false)
        c.listener.start()
        await sleep(0.6)
        let cold = c.listener.micStartMs
        await withCheckedContinuation { cont in c.listener.stop { _ in cont.resume() } }
        check(cold != nil, "cold mic start: first audio \(cold ?? -1) ms after key press")
        // Kept ready: last half second is already buffered.
        c.listener.setAlwaysOn(true)
        await sleep(1.0)
        let pre = c.listener.preRollCount
        check(pre >= 7_000, "keep-mic-ready buffers pre-roll: \(pre) samples (\(pre / 16) ms)")
        c.listener.start()
        check(c.listener.micStartMs == 0, "warm mic start: 0 ms")
        await withCheckedContinuation { cont in c.listener.stop { _ in cont.resume() } }
        c.listener.setAlwaysOn(false)
        check(!c.listener.isEngineRunning, "mic closed again when the setting is off")
        // Waveform and sounds.
        c.overlay.show(heard: "Listening…", color: .systemRed, listening: true)
        for l in [0.1, 0.4, 0.8] as [Float] { c.overlay.level(l) }
        check(!c.overlay.meter.isHidden, "level meter shown while listening")
        c.overlay.hide()
        check(["Tink", "Pop", "Basso", "Morse"].allSatisfy { NSSound(named: NSSound.Name($0)) != nil }, "feedback sounds available")
    }

    func keychain() {
        let fileGone = !FileManager.default.fileExists(atPath: legacyKeyPath)
        let k = Keychain.read()
        check(k?.hasPrefix("sk-") == true, "API key is in the Keychain (\(k.map { "\($0.prefix(7))…" } ?? "missing"))")
        check(fileGone, "plain-text key file removed")
    }

    func macros() async {
        guard let saved = currentVolume() else { check(false, "read volume"); return }
        let store = Store.shared
        let before = store.history.count
        store.macros.append(Macro(phrase: "self test mode", steps: ["volume 30", "volume 50"]))
        c.rescan()
        c.handle("Self test mode.")
        await sleep(1.5)
        check(currentVolume()?.level == 50, "macro ran both steps (volume now \(currentVolume()?.level ?? -1))")
        check(store.history.count == before + 1 && store.history.first?.source == "local", "history recorded: \(store.history.first.map { "\($0.heard) → \($0.labels.joined(separator: ", ")) via \($0.source)" } ?? "nothing")")
        store.macros.removeAll { $0.phrase == "self test mode" }
        runAppleScript("set volume output volume \(saved.level)\nset volume \(saved.muted ? "with" : "without") output muted")
        let s = store.stats
        log("TEST info stats: \(s.count) commands, \(Int(s.localShare * 100))% local, avg speech \(s.avgSpeech ?? -1) ms, avg decide \(s.avgDecide ?? -1) ms")
    }

    func typing() async {
        let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 420, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 25, width: 380, height: 24))
        w.contentView?.addSubview(field)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(field)
        for _ in 0..<50 where !(NSApp.isActive && w.isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(field)
            await sleep(0.1)
        }
        check(NSApp.isActive && w.isKeyWindow, "test window has keyboard focus")
        await sleep(0.3)
        c.targetApp = NSRunningApplication.current
        c.type("Hello from Mac Control, café ✓")
        await sleep(1.2)
        let expected = "Hello from Mac Control, café ✓ "
        let foreign = field.stringValue.hasSuffix(expected) ? String(field.stringValue.dropLast(expected.count)) : ""
        check(field.stringValue.hasSuffix(expected), "typed text arrived intact: \"\(field.stringValue)\"" + (foreign.isEmpty ? "" : " (\"\(foreign)\" came from live keyboard input during the test)"))
        w.close()
        NSApp.setActivationPolicy(.accessory)
    }

    func settings() async {
        SettingsWindow.shared.show(c, tab: .setup)
        await sleep(1.0)
        check(SettingsWindow.shared.isVisible, "Settings window opens")
        for ch in SettingsWindow.shared.setup.checks { log("TEST info setup: \(ch.ok.map { $0 ? "✓" : "✗" } ?? "·") \(ch.title) — \(ch.detail)") }
        check(SettingsWindow.shared.setup.checks.contains { $0.id == "ax" && $0.ok == true }, "setup shows Accessibility allowed")
        for t in SettingsTab.allCases { SettingsWindow.shared.router.tab = t; await sleep(0.4) }
        check(true, "switched through all tabs without crashing")
        let p = Prefs.shared
        let old = p.overlayPosition
        p.overlayPosition = .bottom
        check(c.overlay.position == .bottom, "changing a preference applies immediately")
        p.overlayPosition = old
        await sleep(3)
    }

    func limit() async {
        let (calc, wasRunning) = await bringUp("/System/Applications/Calculator.app")
        guard let calc else { check(false, "Calculator opened"); return }
        c.targetApp = calc; c.targetBrowser = nil
        let real = collectMenuItems(calc)
        log("TEST info View menu: \(real.filter { $0.label.hasPrefix("View ›") }.map(\.label).joined(separator: " | "))")
        let modes = ["› Scientific", "› Basic", "› Programmer"]
        guard let target = real.first(where: { item in modes.contains { item.label.hasSuffix($0) } }) else {
            check(false, "found a View mode item"); return
        }
        let mode = target.label.components(separatedBy: "› ").last!.lowercased()
        // Flood the list: 300 extra menu items, with the real one buried at the end.
        c.menuItems = (0..<300).map { UIAction(label: "Format › Style \($0)", element: target.element, role: "menu item") } + [target]
        c.windowControls = collectWindowControls(calc)
        let heard = "switch to \(mode) mode"
        let choices = c.buildChoices(for: heard)
        check(choices.count <= Controller.maxChoices, "options capped at \(choices.count) (limit \(Controller.maxChoices))")
        check(choices.contains { c.labels[$0.value] == "Menu command in Calculator: \(target.label)" }, "\"\(target.label)\" survived the cap")
        let r = await decide(heard)
        check(r?.error == nil, "API accepted the request (\(r?.error ?? "no error"))")
        check(label(r?.steps.first?.choice) == "menu \(target.label)", "\"\(heard)\" → \(label(r?.steps.first?.choice))")
        if !wasRunning { calc.terminate() }
    }

    func waitFor(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; await sleep(0.2) }
        return cond()
    }

    func fallback() async {
        guard let saved = currentVolume() else { check(false, "read volume"); return }
        defer { runAppleScript("set volume output volume \(saved.level)\nset volume \(saved.muted ? "with" : "without") output muted") }
        c.rescan(); await sleep(1.5)
        c.targetApp = NSWorkspace.shared.frontmostApplication; c.targetBrowser = nil
        c.menuItems = []; c.windowControls = []
        let realClient = c.client
        let health = await withCheckedContinuation { cont in c.localDecider.health { cont.resume(returning: ($0, $1)) } }
        check(health.0, "local Decider reachable: \(health.1)")

        // 1. OpenAI rejects the request (bad key) → local Decider answers.
        c.client = DecisionClient(key: "sk-invalid-selftest-key")
        var t0 = Date()
        c.decide("set the volume to thirty")
        let ok1 = await waitFor(40) { currentVolume()?.level == 30 }
        check(ok1, "OpenAI failed → local Decider set volume to 30 in \(Int(Date().timeIntervalSince(t0) * 1000)) ms total")
        check(c.overlay.current.meta.contains("local Decider"), "overlay says who decided: \(c.overlay.current.meta)")

        // 2. No OpenAI key at all.
        c.client = nil
        t0 = Date()
        c.decide("turn the sound up to sixty percent")
        let ok2 = await waitFor(40) { currentVolume()?.level == 60 }
        check(ok2, "no OpenAI key → local Decider set volume to 60 in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

        // 3. Chained command through the local model.
        runAppleScript("set volume without output muted")
        t0 = Date()
        c.decide("set the volume to forty and then mute it")
        let ok3 = await waitFor(60) { currentVolume().map { $0.level == 40 && $0.muted } ?? false }
        check(ok3, "chained via local Decider: volume 40 then mute (\(Int(Date().timeIntervalSince(t0) * 1000)) ms) — \(c.overlay.current.picked)")

        // 4. Both unavailable → clear error, nothing run.
        let url = Prefs.shared.localDeciderURL
        Prefs.shared.localDeciderURL = "http://127.0.0.1:9"
        let before = currentVolume()?.level
        c.decide("set the volume to ninety")
        let ok4 = await waitFor(15) { c.overlay.current.picked.contains("Local Decider") }
        check(ok4 && currentVolume()?.level == before, "both down → error shown, nothing run: \(c.overlay.current.picked.replacingOccurrences(of: "\n", with: " | "))")
        Prefs.shared.localDeciderURL = url

        c.client = realClient
        SettingsWindow.shared.show(c, tab: .setup)
        let ok5 = await waitFor(5) { SettingsWindow.shared.setup.checks.contains { $0.id == "local" && $0.ok == true } }
        check(ok5, "Setup shows the local Decider as ready")
    }
}
