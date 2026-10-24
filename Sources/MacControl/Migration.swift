// One-time move of everything the app stored back when it was called "Voice Control" (bundle id local.voicecontrol).
import Foundation

let legacyBundleID = "local.voicecontrol"
let migratedKey = "migratedFromVoiceControl"

/// Settings, credit counter, history, macros and the API key carry over; the old copies are removed.
/// Runs before anything reads preferences or the store.
func migrateFromVoiceControl() {
    let d = UserDefaults.standard
    guard !d.bool(forKey: migratedKey) else { return }
    defer { d.set(true, forKey: migratedKey) }
    var moved: [String] = []

    if let old = UserDefaults(suiteName: legacyBundleID) {
        let keys = ["hotkey", "speechModel", "pickerThreshold", "confirmThreshold", "alwaysConfirm", "overlayPosition", "sounds",
                    "keepMicReady", "localFallback", "localDeciderURL", "creditBalance", "creditSpent", "creditCalls",
                    "creditExhausted", "priceInput", "priceCached"]
        for k in keys where d.object(forKey: k) == nil {
            if let v = old.persistentDomain(forName: legacyBundleID)?[k] { d.set(v, forKey: k); moved.append(k) }
        }
    }

    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let oldDir = support.appendingPathComponent("VoiceControl"), newDir = support.appendingPathComponent("MacControl")
    if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path), (try? fm.moveItem(at: oldDir, to: newDir)) != nil {
        moved.append("history and macros")
    }

    if Keychain.read() == nil, let key = Keychain.read(service: Keychain.legacyService), Keychain.write(key), Keychain.read() == key {
        Keychain.delete(service: Keychain.legacyService)
        moved.append("API key")
    }
    log("migrated from Voice Control: \(moved.isEmpty ? "nothing to move" : moved.joined(separator: ", "))")
}
