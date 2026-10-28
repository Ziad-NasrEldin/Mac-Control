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
            case "utterance": utterance()
            case "stream": await streamDemo()
            case "endpoint": await endpoint()
            case "live": await live()
            case "handsfree": await handsFree()
            case "bark": await barkTyping()
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
            ("Alright. Can you open up the Notes app for me?", "open:Notes"), ("Could you please open Safari", "open:Safari"),
            ("Now, can you open up X.com?", "url:https://x.com"), ("go to github dot com", "url:https://github.com"),
            ("Okay, can you mute", "system:mute"), ("open the notes", "open:Notes"),
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

    func utterance() {
        let cases: [(String, Bool, [String], String?, Int)] = [
            ("open the notes app", false, ["open the notes app"], nil, 0),
            ("Open the notes app and", false, ["Open the notes app"], nil, 1),
            ("Open the notes app and create a new", false, ["Open the notes app", "create a new"], nil, 1),
            ("Open the notes app and create a new note that says hello, this is a test.", true,
             ["Open the notes app", "create a new note"], "Hello, this is a test.", 2),
            ("Open the notes app and create a new note that says hello", false, ["Open the notes app", "create a new note"], "Hello", 2),
            ("type hello world", true, [], "Hello world", 0),
            ("open Safari and search for salt and pepper", true, ["open Safari", "search for salt and pepper"], nil, 2),
            ("open Safari and search for salt", false, ["open Safari", "search for salt"], nil, 1),
            ("Open Notes. Create a new note.", true, ["Open Notes", "Create a new note"], nil, 2),
            ("volume 40", false, ["volume 40"], nil, 0),
            ("Alright. Can you open up the Notes app for me? And", false, ["Alright", "Can you open up the Notes app for me"], nil, 2),
            ("Okay, let's make the title say 'Hello.'", true, ["Okay", "let's make the title"], "Hello.", 2),
            ("can you say that again", true, ["can you say that again"], nil, 1),
        ]
        for (said, final, clauses, text, complete) in cases {
            let u = Utterance.parse(said, final: final)
            check(u.clauses == clauses && u.text == text && u.complete == complete,
                  "\(final ? "final" : "partial") \"\(said)\" → \(u.clauses) text=\(u.text ?? "-") ready=\(u.complete)")
        }
        check(Utterance.looksLikeCommand("create a new note") && !Utterance.looksLikeCommand("the weather today"), "command detection")
        check(Utterance.looksLikeCommand("Alright, can you open up the Notes app for me?") && Utterance.looksLikeCommand("let's make a new note"),
              "command detection through polite phrasing")
        for (said, expect) in [("Alright. Can you open up the Notes app for me?", "open up the Notes app"), ("Now, can you open up X.com?", "open up X.com"),
                               ("And once you're there, can you Google search Norbert Wiener?", "Google search Norbert Wiener"),
                               ("let's make a new note", "make a new note")] {
            check(Utterance.core(said) == expect, "core \"\(said)\" → \"\(Utterance.core(said))\"")
        }
        for (said, chatter) in [("Great, great.", true), ("Cool, awesome. Thank you.", true), ("Okay", true), ("once you're there", true),
                                ("open notes", false), ("Safari", false), ("make it bigger", false)] {
            check(Utterance.isChatter(said) == chatter, "chatter \"\(said)\" → \(Utterance.isChatter(said))")
        }
        for (said, expect) in [("Great, great. Okay, can you open up the Arc browser?", "can you open up the Arc browser?"),
                               ("search for salt and pepper. Thanks.", "search for salt and pepper"),
                               ("Create a new note that says great, thanks", "Create a new note that says great, thanks"),
                               ("Cool, awesome. Thank you.", "")] {
            check(Utterance.dropChatter(said) == expect, "chatter dropped from \"\(said)\" → \"\(Utterance.dropChatter(said))\"")
        }
        let chrome = Utterance.parse("open Google Chrome", final: false)
        check(!chrome.searching && chrome.clauses == ["open Google Chrome"], "\"open Google Chrome\" isn't a search: \(chrome.clauses)")
        // Final clauses are matched to what already ran by their words, not their position.
        let ran = [(words: Controller.words("Okay open Safari"), action: "open:Safari"), (words: Controller.words("open Notes"), action: "open:Notes")]
        let left = Controller.remaining(["Okay", "open Safari", "new tab"], ran: Array(ran.prefix(1)))
        check(left.map(\.clause) == ["new tab"] && left[0].ran == nil, "re-punctuated final: \(left.map(\.clause))")
        let grew = Controller.remaining(["open Notes in a new window"], ran: Array(ran.suffix(1)))
        check(grew.count == 1 && grew[0].ran == "open:Notes", "grown clause decided again: \(grew.map { "\($0.clause) (ran \($0.ran ?? "-"))" })")
        check(searchQuery(from: "can you Google search Norbert Wiener for me?") == "Norbert Wiener",
              "search query: \"\(searchQuery(from: "can you Google search Norbert Wiener for me?"))\"")
    }

    /// Pauses end utterances: two phrases with a second of quiet between them are two utterances, a short gap isn't.
    func endpoint() async {
        let quiet = [Float](repeating: 0, count: 16_000)
        let noise = (0..<16_000).map { _ in Float.random(in: -0.002...0.002) }
        // A fan or music that starts mid-sentence and never stops: the pause after the speech still has to be found.
        let hum = (0..<48_000).map { Float(sin(Double($0) * 0.07) * 0.03) }
        for (name, gap, tail, expect) in [("one-second pause", quiet, quiet, 2), ("one-second pause over room noise", noise, quiet, 2),
                                          ("quarter-second gap", Array(quiet.prefix(4_000)), quiet, 1),
                                          ("steady hum after speaking", quiet, hum, 2)] {
            let audio = synthesize("open notes") + gap + synthesize("create a new note") + tail
            var gate = SpeechGate(), ends = 0, sinceTick = 0
            var at = 0
            while at < audio.count {
                gate.push(Array(audio[at..<min(at + 341, audio.count)]))
                at += 341; sinceTick += 341
                if sinceTick >= 2_400 { sinceTick = 0; if gate.ended(after: 0.7, long: false) { ends += 1; gate.reset() } }
            }
            check(ends == expect, "\(name): \(ends) utterance(s), expected \(expect)")
        }
    }

    /// The clause still being spoken runs once two transcripts agree, before any "and" or pause.
    func live() async {
        c.rescan(); await sleep(1)
        let wasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Notes" }
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        await sleep(0.5)
        let actWhileTalking = Prefs.shared.actWhileTalking
        Prefs.shared.actWhileTalking = true
        c.stream = StreamState(); c.finishing = false
        c.snapshot()
        c.holding = true; c.typingMode = false
        var openedAt: String?
        for p in ["Alright.", "Alright. Can you open", "Alright. Can you open up the", "Alright. Can you open up the Notes",
                  "Alright. Can you open up the Notes app", "Alright. Can you open up the Notes app for me"] {
            c.streamPartial(p)
            await sleep(0.3)
            if openedAt == nil, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes" { openedAt = p }
        }
        if openedAt == nil, await waitFor(3, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes" }) { openedAt = "(late)" }
        check(openedAt != nil && openedAt != "(late)", "Notes opened mid-sentence, at \"\(openedAt ?? "never")\" — \(c.stream.actions)")
        check(c.stream.actions == ["open:Notes"], "ran exactly once: \(c.stream.actions)")
        // Chatter after it changes nothing, and the end of the turn is quiet.
        c.streamPartial("Alright. Can you open up the Notes app for me? Great, great.")
        await sleep(0.4)
        c.holding = false
        c.finishTurn("Alright. Can you open up the Notes app for me? Great, great.")
        let ended = await waitFor(6) { !self.c.finishing }
        check(c.stream.actions == ["open:Notes"] && ended, "chatter added nothing and the turn ended: \(c.stream.actions)")
        if !wasRunning { NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.Notes" }?.terminate() }

        // "dark mode" mustn't run while "… off" may still be coming; "volume 4…" never runs early.
        check(c.couldGrow("system:darkon", words: "dark mode") && !c.couldGrow("system:mute", words: "mute volume"),
              "phrases that can still grow wait for the end")

        // A final that arrives while another turn is running is queued, and its stale live transcript is dropped.
        c.stream = StreamState(); c.finishing = true; c.holding = true; c.queuedFinals = []
        c.streamPartial("new tab and")
        check(c.heldPartial == "new tab and", "live transcript held while a turn runs")
        c.utteranceEnded("new tab and scroll down")
        check(c.heldPartial == nil && c.queuedFinals == ["new tab and scroll down"], "final queued, held transcript dropped")
        c.queuedFinals = []; c.finishing = false; c.holding = false
        Prefs.shared.actWhileTalking = actWhileTalking
    }

    /// Speaks out loud through the Mac's speakers, without blocking the main thread (live transcription runs there).
    func speakAloud(_ text: String) async {
        await Task.detached { _ = runTool("/usr/bin/say", ["-r", "190", text]) }.value
    }

    /// End to end through the real microphone: a tap starts hands-free, spoken commands run at each pause with
    /// nobody touching a key, chatter does nothing, "stop listening" ends it. Plays speech through the speakers.
    func handsFree() async {
        guard await waitParakeet() else { check(false, "Parakeet loaded"); return }
        c.rescan(); await sleep(1)
        let wasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Notes" }
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        await sleep(0.5)
        // A tap: press, release within 0.35 s with nothing said.
        c.holding = true; c.typingMode = false; c.pressedAt = Date(); c.begin()
        await sleep(0.15)
        c.holding = false
        c.startHandsFree()
        check(c.handsFree && c.listener.isEngineRunning, "tap → hands-free, mic on")
        await sleep(0.8)

        var loudest: Float = 0
        let meter = c.listener.onLevel
        c.listener.onLevel = { l in loudest = max(loudest, l); meter?(l) }
        var partials: [String] = []
        let live = c.listener.onStreamText
        c.listener.onStreamText = { t in partials.append(t); live?(t) }
        let start = Date()
        await speakAloud("Alright. Can you open up the Notes app for me?")
        let spokenAt = Date().timeIntervalSince(start)
        let opened = await waitFor(4) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes" }
        let openedAt = Date().timeIntervalSince(start)
        check(opened, "spoken \"open up the Notes app\" opened Notes with no key held (speech ended \(String(format: "%.1f", spokenAt)) s, Notes in front by \(String(format: "%.1f", openedAt)) s)")
        log("TEST info turns so far: \(c.recent.map { "\($0.heard) → \($0.did)" }) · loudest mic level \(loudest) · room level \(c.listener.noiseFloor) · live transcripts: \(partials)")

        await sleep(1.5)
        let before = c.recent.count
        await speakAloud("Great, great. Thank you.")
        await sleep(2)
        check(c.recent.count == before && c.handsFree, "chatter did nothing and kept listening")

        log("TEST info gate after quiet: \(c.listener.gateState) · heard since: \(partials.suffix(4))")
        await speakAloud("Stop listening.")
        let stopped = await waitFor(4) { !self.c.handsFree }
        log("TEST info after \"stop listening\": \(c.listener.gateState) · heard: \(partials.suffix(3))")
        check(stopped, "\"stop listening\" ended hands-free")
        await sleep(0.5)
        check(!c.listener.isEngineRunning || c.listener.alwaysOn, "mic closed afterwards")
        if !wasRunning { NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.Notes" }?.terminate() }
    }

    /// Typing mode's final transcript comes from Bark 3.0 Pro; compares it with Parakeet on the same audio.
    func barkTyping() async {
        check(BarkModel.isInstalled, "Bark 3.0 Pro installed at \(BarkModel.directory.path)")
        guard await waitParakeet() else { check(false, "Parakeet loaded"); return }
        Prefs.shared.barkForTyping = true
        c.applyPrefs()
        let loaded = await waitFor(120) { self.c.bark.ready }
        check(loaded, "Bark loaded: \(c.bark.status)")
        guard loaded else { return }
        for phrase in ["Hi Sarah, could you send me the quarterly report by Thursday afternoon?",
                       "The meeting with Doctor Nasr Eldin is moved to 3:45 PM in the Cairo office."] {
            let audio = synthesize(phrase)
            let (p, pms) = await withCheckedContinuation { cont in c.listener.parakeet.transcribe(audio) { cont.resume(returning: ($0, $1)) } }
            let (b, bms) = await withCheckedContinuation { cont in c.bark.transcribe(audio) { cont.resume(returning: ($0, $1)) } }
            log("TEST info said:    \(phrase)\n  parakeet (\(pms) ms): \(p)\n  bark     (\(bms) ms): \(b)")
            check(!b.isEmpty && FastPath.normalize(b).split(separator: " ").count >= 8, "Bark transcribed it in \(bms) ms (Parakeet \(pms) ms)")
        }
        // Typing mode routes its final transcripts to Bark; commands don't.
        c.typingMode = true; c.useTypingEngine()
        check(c.listener.finalEngine === c.bark, "typing mode uses Bark for final transcripts")
        c.typingMode = false; c.useTypingEngine()
        check(c.listener.finalEngine == nil, "command mode stays on Parakeet")
    }

    func focusedText(_ app: NSRunningApplication) -> String {
        let a = AXUIElementCreateApplication(app.processIdentifier)
        guard let f = axAttr(a, kAXFocusedUIElementAttribute) else { return "" }
        return (axAttr(f as! AXUIElement, kAXValueAttribute) as? String) ?? ""
    }

    func streamDemo() async {
        check(await waitParakeet(), "Parakeet loaded")
        // Live transcription of a growing recording yields the beginning of the sentence.
        let full = synthesize("Open text edit and create a new document")
        let (early, earlyMs) = await withCheckedContinuation { cont in c.listener.transcribe(samples: Array(full.prefix(full.count * 45 / 100))) { cont.resume(returning: ($0, $1)) } }
        check(FastPath.normalize(early).hasPrefix("open text"), "live transcript of the first half: \"\(early)\" in \(earlyMs) ms")

        c.rescan(); await sleep(1.5)
        let wasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.TextEdit" }
        Prefs.shared.actWhileTalking = true
        c.targetApp = NSWorkspace.shared.frontmostApplication; c.targetBrowser = nil
        c.menuItems = []; c.windowControls = []
        c.stream = StreamState()
        c.stream.intended = c.targetApp
        c.holding = true; c.typingMode = false
        // Partial transcripts as they'd arrive while speaking, ~0.4 s apart.
        let partials = ["Open", "Open text edit", "Open text edit and", "Open text edit and create a", "Open text edit and create a new document",
                        "Open text edit and create a new document that says", "Open text edit and create a new document that says hello",
                        "Open text edit and create a new document that says hello this is a test"]
        var openedAt: Int?
        for (i, p) in partials.enumerated() {
            c.streamPartial(p)
            await sleep(0.4)
            if openedAt == nil, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" { openedAt = i }
        }
        check(openedAt != nil && openedAt! < partials.count - 1,
              "TextEdit came forward while still talking (after partial \((openedAt ?? -2) + 1) of \(partials.count): \"\(openedAt.map { partials[$0] } ?? "-")\")")
        let earlyActions = c.stream.actions
        log("TEST info ran before release: \(earlyActions.map(c.describe))")
        // Let go.
        c.holding = false
        c.stream.releasedAt = Date()
        c.finishUtterance("Open text edit and create a new document that says hello, this is a test.")
        let edit = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" }
        let typed = await waitFor(20) { edit.map { self.focusedText($0).contains("Hello, this is a test.") } ?? false }
        check(typed, "new document contains the dictated text: \"\(edit.map(focusedText) ?? "")\"")
        check(c.stream.actions.contains { $0.hasPrefix("menu:") }, "\"create a new document\" ran a TextEdit menu command: \(c.stream.actions.map(c.describe))")
        log("TEST info overlay: \(c.overlay.current.picked) | \(c.overlay.current.meta)")

        // Focus theft: another app comes to the front before the dictated text is typed → nothing is typed.
        c.stream = StreamState()
        c.targetApp = edit; c.stream.intended = edit
        c.holding = true
        for p in ["Create a new document and", "Create a new document that says this must not be typed"] { c.streamPartial(p); await sleep(0.5) }
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        await sleep(0.6)
        c.holding = false
        c.stream.releasedAt = Date()
        c.finishUtterance("Create a new document that says this must not be typed.")
        await sleep(3)
        check(!c.stream.actions.contains { $0.hasPrefix("type:") } && c.stream.blockedBy != nil,
              "focus stolen → nothing typed: \(c.stream.blockedBy ?? "not blocked!")")
        edit?.activate(); await sleep(0.6)

        // Clean up: close the test documents without saving.
        if let edit {
            for _ in 0..<3 {
                guard let close = collectMenuItems(edit).first(where: { $0.label == "File › Close" }) else { break }
                press(close.element)
                await sleep(0.8)
                if let dont = collectWindowControls(edit).first(where: { ["Delete", "Don’t Save", "Don't Save"].contains($0.label) }) { press(dont.element) }
                await sleep(0.5)
            }
            if !wasRunning { edit.terminate() }
        }
    }
}

