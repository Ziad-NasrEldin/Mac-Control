import AppKit
import ApplicationServices

// MARK: - Config

// Hotkey: hold Command + Right Option. NX_DEVICERALTKEYMASK tells right Option apart from left.
let rightOptionMask: UInt = 0x40
let maxPageElements = 120
let browserBundleIDs: [String: BrowserKind] = [
    "com.apple.Safari": .safari,
    "com.apple.SafariTechnologyPreview": .safari,
    "com.google.Chrome": .chromium,
    "com.google.Chrome.canary": .chromium,
    "com.brave.Browser": .chromium,
    "com.microsoft.edgemac": .chromium,
    "company.thebrowser.Browser": .chromium, // Arc
    "com.vivaldi.Vivaldi": .chromium,
    "com.operasoftware.Opera": .chromium,
]
enum BrowserKind { case safari, chromium }

let legacyKeyPath = NSString(string: "~/.config/voicecontrol/openai_key").expandingTildeInPath

/// The OpenAI key: environment, then Keychain. A key left in the old plain-text file is moved into the Keychain.
func loadAPIKey() -> String? {
    if let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !k.isEmpty { return k }
    if let k = Keychain.read(), !k.isEmpty { return k }
    guard let k = (try? String(contentsOfFile: legacyKeyPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
          !k.isEmpty else { return nil }
    if Keychain.write(k), Keychain.read() == k {
        try? FileManager.default.removeItem(atPath: legacyKeyPath)
        log("moved API key from \(legacyKeyPath) into the Keychain")
    }
    return k
}

let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    return dir.appendingPathComponent("VoiceControl.log")
}()
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
