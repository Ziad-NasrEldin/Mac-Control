import AppKit
import ApplicationServices

// MARK: - System controls

// NX_KEYTYPE_* codes for the hardware media keys; posting them shows the native volume/brightness HUD.
enum MediaKey: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7, play = 16, next = 17, previous = 18 }

func sendMediaKey(_ key: MediaKey, times: Int = 1) {
    for _ in 0..<times {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key.rawValue << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Runs AppleScript off the main thread; returns an error message or nil.
@discardableResult
func runAppleScript(_ src: String) -> String? {
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err { log("AppleScript error: \(err)"); return err[NSAppleScript.errorMessage] as? String ?? "AppleScript failed" }
    return nil
}

/// Runs a command line tool; returns an error message or nil.
@discardableResult
func runTool(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let errPipe = Pipe()
    p.standardError = errPipe
    do { try p.run() } catch { return error.localizedDescription }
    p.waitUntilExit()
    guard p.terminationStatus != 0 else { return nil }
    let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return msg?.isEmpty == false ? msg : "\(path) exited \(p.terminationStatus)"
}

// Shortcut names the user creates once in the Shortcuts app (there's no public API to change Focus).
let dndOnShortcut = "Do Not Disturb On"
let dndOffShortcut = "Do Not Disturb Off"

let systemChoices: [Choice] = {
    var c = [
        Choice(value: "system:volumeup", description: "Turn the volume up / louder"),
        Choice(value: "system:volumedown", description: "Turn the volume down / quieter"),
        Choice(value: "system:mute", description: "Mute or unmute the sound"),
        Choice(value: "system:brightnessup", description: "Make the screen brighter"),
        Choice(value: "system:brightnessdown", description: "Make the screen dimmer / darker brightness"),
        Choice(value: "system:playpause", description: "Play or pause music / media"),
        Choice(value: "system:next", description: "Skip to the next track / song"),
        Choice(value: "system:previous", description: "Go to the previous track / song"),
        Choice(value: "system:dndon", description: "Turn on Do Not Disturb / Focus"),
        Choice(value: "system:dndoff", description: "Turn off Do Not Disturb / Focus"),
        Choice(value: "system:lock", description: "Lock the screen / lock the Mac"),
        Choice(value: "system:sleepdisplay", description: "Turn off / sleep the display"),
        Choice(value: "system:screenshot", description: "Take a screenshot of the whole screen"),
        Choice(value: "system:screenshotarea", description: "Take a screenshot of a selected area / part of the screen"),
        Choice(value: "system:screenshottool", description: "Open the screenshot / screen recording tool"),
        Choice(value: "system:darkon", description: "Turn on dark mode"),
        Choice(value: "system:darkoff", description: "Turn on light mode / turn off dark mode"),
        Choice(value: "system:darktoggle", description: "Toggle / switch between dark and light mode"),
    ]
    for v in stride(from: 0, through: 100, by: 10) {
        c.append(Choice(value: "system:volume=\(v)", description: v == 0 ? "Set the volume to 0% / silent" : "Set the volume to \(v)%"))
    }
    return c
}()

/// Performs a `system:` action. Calls `fail` on the main thread with a message if it couldn't be done.
func performSystem(_ cmd: String, fail: @escaping (String) -> Void) {
    func bg(_ work: @escaping () -> String?) {
        scriptQueue.async { if let e = work() { DispatchQueue.main.async { fail(e) } } }
    }
    let darkScript = { (expr: String) in
        "tell application \"System Events\" to tell appearance preferences to set dark mode to \(expr)"
    }
    if cmd.hasPrefix("volume="), let v = Int(cmd.dropFirst(7)) {
        bg { runAppleScript("set volume output volume \(v)" + (v > 0 ? "\nset volume without output muted" : "")) }
        return
    }
    switch cmd {
    case "volumeup": sendMediaKey(.soundUp, times: 2)
    case "volumedown": sendMediaKey(.soundDown, times: 2)
    case "mute": sendMediaKey(.mute)
    case "brightnessup": sendMediaKey(.brightnessUp, times: 2)
    case "brightnessdown": sendMediaKey(.brightnessDown, times: 2)
    case "playpause": sendMediaKey(.play)
    case "next": sendMediaKey(.next)
    case "previous": sendMediaKey(.previous)
    case "lock": sendKey(12, flags: [.maskCommand, .maskControl])                 // ⌃⌘Q
    case "sleepdisplay": bg { runTool("/usr/bin/pmset", ["displaysleepnow"]) }
    case "screenshot": sendKey(20, flags: [.maskCommand, .maskShift])             // ⇧⌘3
    case "screenshotarea": sendKey(21, flags: [.maskCommand, .maskShift])         // ⇧⌘4
    case "screenshottool": sendKey(23, flags: [.maskCommand, .maskShift])         // ⇧⌘5
    case "darkon": bg { runAppleScript(darkScript("true")) }
    case "darkoff": bg { runAppleScript(darkScript("false")) }
    case "darktoggle": bg { runAppleScript(darkScript("not dark mode")) }
    case "dndon", "dndoff":
        let name = cmd == "dndon" ? dndOnShortcut : dndOffShortcut
        bg {
            runTool("/usr/bin/shortcuts", ["run", name]).map { _ in "Create a shortcut named “\(name)” in the Shortcuts app (Set Focus action)" }
        }
    default: fail("Unknown system action \(cmd)")
    }
}
