import AppKit
import ApplicationServices

// MARK: - Apps

struct AppEntry { let name: String; let url: URL; let bundleID: String? }

func scanApplications() -> [AppEntry] {
    let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                 NSString(string: "~/Applications").expandingTildeInPath]
    var seen = Set<String>(), out: [AppEntry] = []
    for root in roots {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for item in items where item.hasSuffix(".app") {
            let url = URL(fileURLWithPath: root).appendingPathComponent(item)
            let name = (item as NSString).deletingPathExtension
            if seen.insert(name.lowercased()).inserted {
                out.append(AppEntry(name: name, url: url, bundleID: Bundle(url: url)?.bundleIdentifier))
            }
        }
    }
    return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
