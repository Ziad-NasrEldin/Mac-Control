import AppKit
import ApplicationServices

// MARK: - Window management (Accessibility API on the front app's focused window)

let windowChoices: [Choice] = [
    Choice(value: "window:minimize", description: "Minimize / hide the current window to the Dock"),
    Choice(value: "window:close", description: "Close the current window"),
    Choice(value: "window:fullscreen", description: "Toggle full screen for the current window (enter or exit full screen)"),
    Choice(value: "window:maximize", description: "Maximize / fill / zoom / make the current window as big as the screen (not full screen)"),
    Choice(value: "window:center", description: "Center the current window on the screen"),
    Choice(value: "window:left", description: "Tile / snap / move the current window to the left half of the screen"),
    Choice(value: "window:right", description: "Tile / snap / move the current window to the right half of the screen"),
    Choice(value: "window:top", description: "Tile the current window to the top half of the screen"),
    Choice(value: "window:bottom", description: "Tile the current window to the bottom half of the screen"),
    Choice(value: "window:nextdisplay", description: "Move the current window to the other / next display / monitor / screen"),
]

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    let w = axAttr(a, kAXFocusedWindowAttribute) ?? axAttr(a, kAXMainWindowAttribute)
    return w.map { $0 as! AXUIElement }
}

/// Window frame in AX coordinates (origin at the top-left of the primary screen).
func axFrame(_ w: AXUIElement) -> CGRect? {
    guard let p = axAttr(w, kAXPositionAttribute), let s = axAttr(w, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func setAXFrame(_ w: AXUIElement, _ r: CGRect) {
    var pt = r.origin, sz = r.size
    let p = AXValueCreate(.cgPoint, &pt)!, s = AXValueCreate(.cgSize, &sz)!
    // Position, size, position, size: apps clamp size against the old position, and some (fixed aspect
    // ratio) settle only on the second size.
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
}

var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func toAX(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

func screen(forAX r: CGRect) -> NSScreen {
    let center = NSPoint(x: r.midX, y: primaryHeight - r.midY)
    return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// macOS's own Window-menu tiling commands (Fill leaves the system's clean margin around the window).
let windowMenuTitles: [String: Set<String>] = [
    "maximize": ["Fill"], "center": ["Center"], "left": ["Left"], "right": ["Right"], "top": ["Top"], "bottom": ["Bottom"],
]
// Used only when an app has no standard Window menu.
let tileMargin: CGFloat = 8

/// Presses a leaf item with one of `titles` inside the app's Window menu. Returns false if there isn't one.
func pressWindowMenuItem(_ app: NSRunningApplication, titles: Set<String>) -> Bool {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    guard let bar = axAttr(a, kAXMenuBarAttribute),
          let items = axAttr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
          let windowMenu = items.first(where: { (axAttr($0, kAXTitleAttribute) as? String) == "Window" }) else { return false }
    func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5, let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids {
            let isLeaf = (axAttr(k, kAXChildrenAttribute) as? [AXUIElement])?.isEmpty ?? true
            if isLeaf, let t = axAttr(k, kAXTitleAttribute) as? String, titles.contains(t),
               (axAttr(k, kAXEnabledAttribute) as? Bool) != false { return k }
            if let found = search(k, depth: depth + 1) { return found }
        }
        return nil
    }
    guard let item = search(windowMenu, depth: 0) else { return false }
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
}

func performWindow(_ cmd: String, app: NSRunningApplication?, fail: (String) -> Void) {
    guard AXIsProcessTrusted() else { fail("Accessibility permission needed — re-add Voice Control in Settings"); return }
    guard let app, let w = focusedWindow(of: app) else { fail("No window to act on"); return }
    switch cmd {
    case "minimize":
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    case "close":
        guard let b = axAttr(w, kAXCloseButtonAttribute) else { fail("This window can't be closed"); return }
        AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
    case "fullscreen":
        let on = (axAttr(w, "AXFullScreen") as? Bool) ?? false
        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (!on) as CFBoolean)
    default:
        if let titles = windowMenuTitles[cmd], pressWindowMenuItem(app, titles: titles) {
            log("window \(cmd) \(app.localizedName ?? "") via Window menu")
            return
        }
        guard let cur = axFrame(w) else { fail("Couldn't read the window's position"); return }
        let scr = screen(forAX: cur)
        let vf = toAX(scr.visibleFrame)
        let m = vf.insetBy(dx: tileMargin, dy: tileMargin)
        let halfW = (m.width - tileMargin) / 2, halfH = (m.height - tileMargin) / 2
        let target: CGRect
        switch cmd {
        case "maximize": target = m
        case "center": target = CGRect(x: vf.midX - cur.width / 2, y: vf.midY - cur.height / 2, width: cur.width, height: cur.height)
        case "left": target = CGRect(x: m.minX, y: m.minY, width: halfW, height: m.height)
        case "right": target = CGRect(x: m.maxX - halfW, y: m.minY, width: halfW, height: m.height)
        case "top": target = CGRect(x: m.minX, y: m.minY, width: m.width, height: halfH)
        case "bottom": target = CGRect(x: m.minX, y: m.maxY - halfH, width: m.width, height: halfH)
        case "nextdisplay":
            let screens = NSScreen.screens
            guard screens.count > 1, let i = screens.firstIndex(of: scr) else { fail("Only one display connected"); return }
            let nf = toAX(screens[(i + 1) % screens.count].visibleFrame)
            // Keep the window's size (shrunk only if it doesn't fit) and its relative position on the new display.
            let w = min(cur.width, nf.width), h = min(cur.height, nf.height)
            let fx = vf.width > cur.width ? (cur.minX - vf.minX) / (vf.width - cur.width) : 0.5
            let fy = vf.height > cur.height ? (cur.minY - vf.minY) / (vf.height - cur.height) : 0.5
            target = CGRect(x: nf.minX + max(0, min(1, fx)) * (nf.width - w),
                            y: nf.minY + max(0, min(1, fy)) * (nf.height - h), width: w, height: h)
        default: fail("Unknown window action \(cmd)"); return
        }
        setAXFrame(w, target)
        log("window \(cmd) \(app.localizedName ?? "") \(cur) -> \(axFrame(w).map { "\($0)" } ?? "?")")
    }
}
