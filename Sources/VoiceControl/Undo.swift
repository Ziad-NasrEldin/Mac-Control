// "Undo that": each action records how to reverse itself just before it runs.
import AppKit
import ApplicationServices

struct UndoStep {
    let label: String
    let run: () -> Void
}

func currentVolume() -> (level: Int, muted: Bool)? {
    var err: NSDictionary?
    guard let v = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&err).int32Value,
          let m = NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(&err).booleanValue
    else { return nil }
    return (Int(v), m)
}

func isDarkMode() -> Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

extension Controller {
    /// How to reverse `value`, captured before it runs. Nil when it can't be undone.
    func captureUndo(_ value: String) -> UndoStep? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let (kind, arg) = (parts[0], parts[1])
        let running = NSWorkspace.shared.runningApplications
        switch kind {
        case "open":
            let wasRunning = running.contains { $0.localizedName == arg }
            let previous = NSWorkspace.shared.frontmostApplication
            return UndoStep(label: wasRunning ? "switch back to \(previous?.localizedName ?? "the previous app")" : "quit \(arg)") {
                if wasRunning { previous?.activate() }
                else { NSWorkspace.shared.runningApplications.first { $0.localizedName == arg }?.terminate() }
            }
        case "quit":
            guard let url = running.first(where: { $0.localizedName == arg })?.bundleURL else { return nil }
            return UndoStep(label: "reopen \(arg)") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case "browser":
            let inverse = ["closetab": "reopentab", "reopentab": "closetab", "newtab": "closetab", "back": "forward",
                           "forward": "back", "scrolldown": "scrollup", "scrollup": "scrolldown"][arg]
            guard let inverse else { return nil }
            return UndoStep(label: describe("browser:\(inverse)")) { [weak self] in self?.browserCommand(inverse) }
        case "window":
            guard AXIsProcessTrusted(), let app = targetApp ?? NSWorkspace.shared.frontmostApplication,
                  let w = focusedWindow(of: app) else { return nil }
            switch arg {
            case "close": return nil
            case "minimize":
                return UndoStep(label: "restore the window") {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    app.activate()
                }
            case "fullscreen":
                let wasFull = (axAttr(w, "AXFullScreen") as? Bool) ?? false
                return UndoStep(label: "restore full screen") {
                    AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, wasFull as CFBoolean)
                }
            default:
                guard let frame = axFrame(w) else { return nil }
                return UndoStep(label: "put the window back") {
                    // Set it now, then again once any tiling animation has settled.
                    setAXFrame(w, frame)
                    for delay in [0.3, 0.7] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if axFrame(w) != frame { setAXFrame(w, frame) } }
                    }
                }
            }
        case "system":
            switch arg {
            case _ where arg.hasPrefix("volume") || arg == "mute":
                guard let (level, muted) = currentVolume() else { return nil }
                return UndoStep(label: "restore volume to \(level)%") {
                    runAppleScript("set volume output volume \(level)\nset volume \(muted ? "with" : "without") output muted")
                }
            case "darkon", "darkoff", "darktoggle":
                let wasDark = isDarkMode()
                return UndoStep(label: wasDark ? "dark mode back on" : "light mode back on") {
                    scriptQueue.async {
                        runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(wasDark)")
                    }
                }
            case "brightnessup": return UndoStep(label: "brightness back down") { sendMediaKey(.brightnessDown, times: 2) }
            case "brightnessdown": return UndoStep(label: "brightness back up") { sendMediaKey(.brightnessUp, times: 2) }
            case "playpause": return UndoStep(label: "play/pause again") { sendMediaKey(.play) }
            case "next": return UndoStep(label: "previous track") { sendMediaKey(.previous) }
            case "previous": return UndoStep(label: "next track") { sendMediaKey(.next) }
            default: return nil
            }
        default:
            return nil
        }
    }

    func performUndo() {
        guard !undoSteps.isEmpty else {
            overlay.show(heard: "Nothing to undo", picked: "Menus, clicks, tabs, searches and Shortcuts can't be undone",
                         color: .systemGray, autoHide: 2.5)
            return
        }
        let steps = Array(undoSteps.reversed())
        undoSteps = []
        for s in steps { s.run() }
        log("undo: \(steps.map(\.label).joined(separator: ", "))")
        overlay.show(heard: "Undone", picked: steps.map(\.label).joined(separator: "  ·  "), color: .systemGreen, autoHide: 2)
    }
}
