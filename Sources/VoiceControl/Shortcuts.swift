// The user's Shortcuts (from the Shortcuts app), offered as voice commands.
import Foundation

/// Names of all shortcuts, via the `shortcuts` command line tool.
func listShortcuts() -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    p.arguments = ["list"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { log("shortcuts list failed: \(error)"); return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "")
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Runs a shortcut by name; returns an error message or nil. Blocks, so call off the main thread.
func runShortcut(_ name: String) -> String? {
    runTool("/usr/bin/shortcuts", ["run", name])
}
