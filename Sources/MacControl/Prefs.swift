// User preferences (UserDefaults) and the API key (Keychain).
import AppKit
import Combine
import Security
import ServiceManagement

enum Hotkey: String, CaseIterable, Identifiable {
    case cmdRightOption, ctrlRightOption, rightOption
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cmdRightOption: return "⌘ + Right ⌥"
        case .ctrlRightOption: return "⌃ + Right ⌥"
        case .rightOption: return "Right ⌥ alone"
        }
    }
    /// Whether the hotkey is held in `flags`. Shift may be added on top for typing mode.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.rawValue & rightOptionMask != 0 else { return false }
        switch self {
        case .cmdRightOption: return flags.contains(.command)
        case .ctrlRightOption: return flags.contains(.control)
        case .rightOption: return !flags.contains(.command) && !flags.contains(.control)
        }
    }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    /// Called after any change so the controller can apply it.
    var onChange: (() -> Void)?

    @Published var hotkey: Hotkey { didSet { d.set(hotkey.rawValue, forKey: "hotkey"); onChange?() } }
    @Published var speechModel: SpeechModel { didSet { d.set(speechModel.rawValue, forKey: "speechModel"); onChange?() } }
    /// Below this confidence, show the top 3 to pick from instead of acting.
    @Published var pickerThreshold: Double { didSet { d.set(pickerThreshold, forKey: "pickerThreshold") } }
    /// Destructive actions below this confidence ask first.
    @Published var confirmThreshold: Double { didSet { d.set(confirmThreshold, forKey: "confirmThreshold") } }
    @Published var alwaysConfirm: Bool { didSet { d.set(alwaysConfirm, forKey: "alwaysConfirm") } }
    @Published var overlayPosition: Overlay.Position { didSet { d.set(overlayPosition.rawValue, forKey: "overlayPosition"); onChange?() } }
    @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds"); onChange?() } }
    @Published var keepMicReady: Bool { didSet { d.set(keepMicReady, forKey: "keepMicReady"); onChange?() } }
    /// Run finished clauses ("open the notes app and …") before the user lets go.
    @Published var actWhileTalking: Bool { didSet { d.set(actWhileTalking, forKey: "actWhileTalking") } }
    /// Ask Perplexity's local Decider app when OpenAI fails (errors, outages, no credits, no key).
    @Published var localFallback: Bool { didSet { d.set(localFallback, forKey: "localFallback") } }
    @Published var localDeciderURL: String { didSet { d.set(localDeciderURL, forKey: "localDeciderURL") } }

    private init() {
        hotkey = Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .cmdRightOption
        speechModel = SpeechModel(rawValue: d.string(forKey: "speechModel") ?? "") ?? .english
        pickerThreshold = d.object(forKey: "pickerThreshold") as? Double ?? 0.5
        confirmThreshold = d.object(forKey: "confirmThreshold") as? Double ?? 0.9
        alwaysConfirm = d.bool(forKey: "alwaysConfirm")
        overlayPosition = Overlay.Position(rawValue: d.string(forKey: "overlayPosition") ?? "") ?? .top
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        keepMicReady = d.bool(forKey: "keepMicReady")
        actWhileTalking = d.object(forKey: "actWhileTalking") as? Bool ?? true
        localFallback = d.object(forKey: "localFallback") as? Bool ?? true
        localDeciderURL = d.string(forKey: "localDeciderURL") ?? "http://127.0.0.1:8080"
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { log("launch at login \(newValue) failed: \(error)") }
            objectWillChange.send()
        }
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "io.github.ziadnasreldin.maccontrol"
    static let account = "openai-api-key"

    /// Where the app stored the key when it was called Voice Control.
    static let legacyService = "local.voicecontrol"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(service: String = service) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query(service)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String = service) { SecItemDelete(query(service) as CFDictionary) }
}

// MARK: - Global key catcher

/// While active, swallows a few keys (1–3, Return, Esc) system-wide and reports them, so answering
/// the picker or a confirmation doesn't also type into the front app.
final class KeyCatcher {
    static let shared = KeyCatcher()
    fileprivate var handler: ((Int64) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static let one: Int64 = 18, two: Int64 = 19, three: Int64 = 20, returnKey: Int64 = 36, enter: Int64 = 76, escape: Int64 = 53

    func start(_ handler: @escaping (Int64) -> Bool) {
        stop()
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let clean = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            if clean, let h = KeyCatcher.shared.handler, h(code) { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { log("key catcher: event tap unavailable"); return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        handler = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    var isActive: Bool { tap != nil }
}
