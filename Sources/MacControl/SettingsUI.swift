// Settings window: setup checklist, preferences, macros and command history.
import AppKit
import AVFoundation
import Speech
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case setup = "Setup", general = "General", macros = "Macros", history = "History"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: return "checklist"
        case .general: return "gearshape"
        case .macros: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .setup
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    let router = SettingsRouter()
    let setup = SetupModel()

    func show(_ controller: Controller, tab: SettingsTab) {
        router.tab = tab
        setup.controller = controller
        setup.refresh()
        if window == nil {
            let root = SettingsView(router: router, setup: setup, prefs: Prefs.shared, store: Store.shared)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Mac Control"
            w.contentView = NSHostingView(rootView: root)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

// MARK: - Setup checks

struct Check: Identifiable {
    let id: String
    let title: String
    let detail: String
    let ok: Bool?          // nil = not applicable / unknown
    let fixTitle: String?
    let fix: (() -> Void)?
}

func openPrivacyPane(_ anchor: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
}

/// Whether we may send Apple Events to `bundleID` (without prompting).
func automationStatus(_ bundleID: String) -> OSStatus {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
}

final class SetupModel: ObservableObject {
    weak var controller: Controller?
    @Published var checks: [Check] = []
    @Published var apiKeyDraft = ""
    private var localStatus: (Bool?, String) = (nil, "Checking…")
    private var timer: Timer?

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let ax = AXIsProcessTrusted()
        let hasKey = controller?.client != nil
        let parakeet = controller?.listener.parakeet
        var out: [Check] = [
            Check(id: "key", title: "OpenAI API key", detail: hasKey ? "Stored in your Keychain" : "Paste your key below",
                  ok: hasKey, fixTitle: nil, fix: nil),
            Check(id: "mic", title: "Microphone", detail: mic == .authorized ? "Allowed" : "Needed to hear you",
                  ok: mic == .authorized, fixTitle: mic == .notDetermined ? "Allow" : "Open Settings", fix: {
                if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } } else { openPrivacyPane("Privacy_Microphone") }
            }),
            Check(id: "ax", title: "Accessibility", detail: ax ? "Allowed" : "Needed for the hotkey, windows, menus and key presses",
                  ok: ax, fixTitle: "Open Settings", fix: {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                openPrivacyPane("Privacy_Accessibility")
            }),
            Check(id: "stt", title: "Speech model", detail: parakeet?.status ?? "—", ok: parakeet?.ready, fixTitle: nil, fix: nil),
        ]
        if Prefs.shared.localFallback {
            out.append(Check(id: "local", title: "Local Decider (fallback)", detail: localStatus.1, ok: localStatus.0,
                             fixTitle: localStatus.0 == true ? nil : "Open Decider", fix: {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Decider.app"))
            }))
            controller?.localDecider.health { [weak self] ok, detail in
                guard let self, self.localStatus.0 != ok || self.localStatus.1 != detail else { return }
                self.localStatus = (ok, detail)
                self.refresh()
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, browserBundleIDs[bid] != nil, let name = app.localizedName else { continue }
            let status = automationStatus(bid)
            let (ok, detail): (Bool?, String) = {
                switch status {
                case noErr: return (true, "Allowed — tabs, links and buttons work")
                case OSStatus(errAEEventNotPermitted): return (false, "Denied — tab switching and link clicks won't work")
                case OSStatus(errAEEventWouldRequireUserConsent): return (nil, "Not asked yet")
                default: return (nil, "Status \(status)")
                }
            }()
            out.append(Check(id: "auto-\(bid)", title: "Control \(name)", detail: detail, ok: ok,
                             fixTitle: ok == false ? "Open Settings" : (ok == nil ? "Ask now" : nil), fix: {
                if ok == false { openPrivacyPane("Privacy_Automation") }
                else { scriptQueue.async { runAppleScript("tell application id \"\(bid)\" to count windows") } }
            }))
        }
        checks = out
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard SettingsWindow.shared.isVisible else { return }
                self?.refresh()
            }
        }
    }

    func saveKey() {
        controller?.setAPIKey(apiKeyDraft)
        apiKeyDraft = ""
        refresh()
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject var setup: SetupModel
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: Store

    var body: some View {
        TabView(selection: $router.tab) {
            SetupView(setup: setup).tabItem { Label("Setup", systemImage: SettingsTab.setup.icon) }.tag(SettingsTab.setup)
            GeneralView(prefs: prefs).tabItem { Label("General", systemImage: SettingsTab.general.icon) }.tag(SettingsTab.general)
            MacrosView(store: store).tabItem { Label("Macros", systemImage: SettingsTab.macros.icon) }.tag(SettingsTab.macros)
            HistoryView(store: store).tabItem { Label("History", systemImage: SettingsTab.history.icon) }.tag(SettingsTab.history)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct SetupView: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        Form {
            Section("Everything Mac Control needs") {
                ForEach(setup.checks) { c in
                    HStack(spacing: 10) {
                        Image(systemName: c.ok == true ? "checkmark.circle.fill" : (c.ok == false ? "xmark.circle.fill" : "circle.dotted"))
                            .foregroundStyle(c.ok == true ? .green : (c.ok == false ? .red : .secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.body.weight(.medium))
                            Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let t = c.fixTitle, let fix = c.fix, c.ok != true { Button(t, action: fix) }
                    }
                }
            }
            Section("OpenAI API key") {
                HStack {
                    SecureField("sk-…", text: $setup.apiKeyDraft)
                    Button("Save to Keychain") { setup.saveKey() }.disabled(setup.apiKeyDraft.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralView: View {
    @ObservedObject var prefs: Prefs
    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Hold to talk", selection: $prefs.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                Text("Add ⇧ Shift while holding to type what you say instead of running a command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech") {
                Picker("Model", selection: $prefs.speechModel) {
                    ForEach(SpeechModel.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep mic ready (no clipped first word; mic indicator stays on)", isOn: $prefs.keepMicReady)
                Toggle("Act while I'm still talking (“open Notes and …” opens Notes right away)", isOn: $prefs.actWhileTalking)
            }
            Section("Safety") {
                LabeledContent("Show top 3 below") {
                    Slider(value: $prefs.pickerThreshold, in: 0...0.9, step: 0.05) { Text("") }
                        .frame(width: 200)
                    Text("\(Int(prefs.pickerThreshold * 100))%").monospacedDigit().frame(width: 40)
                }
                LabeledContent("Confirm risky actions below") {
                    Slider(value: $prefs.confirmThreshold, in: 0.5...1, step: 0.05) { Text("") }
                        .frame(width: 200)
                    Text("\(Int(prefs.confirmThreshold * 100))%").monospacedDigit().frame(width: 40)
                }
                Toggle("Always confirm quit, lock, sleep display, close window and Shortcuts", isOn: $prefs.alwaysConfirm)
            }
            Section("Fallback when OpenAI fails") {
                Toggle("Ask Perplexity's local Decider (free, offline, ~4 s per command)", isOn: $prefs.localFallback)
                TextField("Decider address", text: $prefs.localDeciderURL).disabled(!prefs.localFallback)
            }
            Section("Feedback") {
                Picker("Overlay position", selection: $prefs.overlayPosition) {
                    Text("Top of screen").tag(Overlay.Position.top)
                    Text("Bottom of screen").tag(Overlay.Position.bottom)
                }
                Toggle("Sounds", isOn: $prefs.sounds)
                Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

struct MacrosView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Say the phrase to run its steps in order. Each step is a normal command, like “open Slack” or “new tab”. One step makes it an alias.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($store.macros) { $m in
                    HStack(alignment: .firstTextBaseline) {
                        TextField("Phrase, e.g. work mode", text: $m.phrase).frame(width: 170)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Steps, comma separated", text: Binding(
                            get: { m.steps.joined(separator: ", ") },
                            set: { m.steps = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        Button(role: .destructive) { store.macros.removeAll { $0.id == m.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Button("Add Macro") { store.macros.append(Macro(phrase: "", steps: [])) }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: Store
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d HH:mm:ss"; return f }()

    var body: some View {
        let s = store.stats
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                stat("Commands", "\(s.count)")
                stat("Exact (no API)", "\(Int(s.localShare * 100))%")
                stat("Avg speech", s.avgSpeech.map { "\($0) ms" } ?? "—")
                stat("Avg decide", s.avgDecide.map { "\($0) ms" } ?? "—")
                stat("Avg total (API)", s.avgTotalAPI.map { "\($0) ms" } ?? "—")
                Spacer()
                Button("Clear") { store.clearHistory() }
            }
            Table(store.history) {
                TableColumn("Time") { Text(Self.time.string(from: $0.date)).monospacedDigit() }.width(110)
                TableColumn("Heard") { Text($0.heard) }
                TableColumn("Did") { e in Text(e.labels.joined(separator: " → ")).foregroundStyle(e.ok ? .primary : .secondary) }
                TableColumn("Conf") { e in Text(e.confidence.map { "\(Int($0 * 100))%" } ?? "—").monospacedDigit() }.width(44)
                TableColumn("ms") { e in Text([e.sttMs, e.decideMs].compactMap { $0 }.map(String.init).joined(separator: "+")).monospacedDigit() }.width(70)
                TableColumn("Via") { Text($0.source) }.width(48)
            }
        }
    }

    func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
