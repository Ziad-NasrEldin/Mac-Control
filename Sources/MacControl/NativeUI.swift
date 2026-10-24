// Menus and buttons of any native app, read through the Accessibility API and offered as choices.
import AppKit
import ApplicationServices

struct UIAction {
    let label: String
    let element: AXUIElement
    let role: String
}

let maxMenuItems = 250
let maxWindowControls = 80
let uiQueue = DispatchQueue(label: "maccontrol.ui-scan")

func axString(_ el: AXUIElement, _ name: String) -> String? {
    (axAttr(el, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

/// Electron/Chromium apps only build their accessibility tree when asked.
func enableManualAccessibility(_ app: NSRunningApplication) {
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                 "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

/// Every enabled leaf command in the app's menu bar (Apple menu excluded), labeled like "File › Export as PDF…".
func collectMenuItems(_ app: NSRunningApplication) -> [UIAction] {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(a, 0.3)
    guard let bar = axAttr(a, kAXMenuBarAttribute),
          let tops = axAttr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
    var out: [UIAction] = []
    func walk(_ el: AXUIElement, path: [String], depth: Int) {
        guard out.count < maxMenuItems, depth < 6, let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids where out.count < maxMenuItems {
            if axString(k, kAXRoleAttribute) == kAXMenuRole { walk(k, path: path, depth: depth + 1); continue }
            let title = axString(k, kAXTitleAttribute)
            let sub = (axAttr(k, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            if !sub.isEmpty {
                // Services is system-wide noise (dozens of other apps' items).
                if let title, title != "Services" { walk(k, path: path + [title], depth: depth + 1) }
                continue
            }
            guard let title, (axAttr(k, kAXEnabledAttribute) as? Bool) != false else { continue }
            out.append(UIAction(label: (path + [title]).joined(separator: " › "), element: k, role: "menu item"))
        }
    }
    for top in tops.dropFirst() {
        guard let t = axString(top, kAXTitleAttribute) else { continue }
        walk(top, path: [t], depth: 0)
    }
    return out
}

let pressableRoles: [String: String] = [
    kAXButtonRole: "button", kAXCheckBoxRole: "checkbox", kAXRadioButtonRole: "option",
    kAXPopUpButtonRole: "pop-up menu", kAXMenuButtonRole: "menu button", "AXLink": "link",
    "AXTab": "tab", kAXDisclosureTriangleRole: "disclosure triangle",
]
// Title-bar buttons are covered by window commands.
let skippedSubroles: Set<String> = [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole,
                                    kAXFullScreenButtonSubrole, "AXToolbarButton_disabled"]

/// Labeled, enabled controls in the app's focused window (breadth-first, capped).
func collectWindowControls(_ app: NSRunningApplication) -> [UIAction] {
    guard let w = focusedWindow(of: app) else { return [] }
    AXUIElementSetMessagingTimeout(w, 0.3)
    var out: [UIAction] = [], seen = Set<String>()
    var queue: [(AXUIElement, Int)] = [(w, 0)]
    var visited = 0
    while !queue.isEmpty, out.count < maxWindowControls, visited < 4000 {
        let (el, depth) = queue.removeFirst()
        visited += 1
        let role = axString(el, kAXRoleAttribute) ?? ""
        if let kind = pressableRoles[role], !skippedSubroles.contains(axString(el, kAXSubroleAttribute) ?? ""),
           (axAttr(el, kAXEnabledAttribute) as? Bool) != false,
           let label = axString(el, kAXTitleAttribute) ?? axString(el, kAXDescriptionAttribute) ?? axString(el, kAXHelpAttribute),
           label.count <= 80, seen.insert("\(kind)|\(label.lowercased())").inserted {
            out.append(UIAction(label: label, element: el, role: kind))
        }
        guard depth < 18, let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        queue += kids.map { ($0, depth + 1) }
    }
    return out
}

@discardableResult
func press(_ el: AXUIElement) -> Bool {
    AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
}
