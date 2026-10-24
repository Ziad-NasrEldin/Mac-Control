import AppKit
import ApplicationServices

// MARK: - Overlay

/// Live mic level as a row of bars, newest on the right.
final class LevelMeter: NSView {
    private var levels = [Float](repeating: 0, count: 28)
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    func push(_ peak: Float) {
        // Peaks are 0…1 but speech mostly sits low; a square root spreads it out visibly.
        levels.removeFirst()
        levels.append(min(1, sqrt(max(0, peak)) * 1.3))
        needsDisplay = true
    }

    func reset() { levels = levels.map { _ in 0 }; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(levels.count), gap: CGFloat = 2
        let w = (bounds.width - gap * (n - 1)) / n
        color.setFill()
        for (i, l) in levels.enumerated() {
            let h = max(2, CGFloat(l) * bounds.height)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}

final class Overlay {
    enum Position: String, CaseIterable { case top, bottom }

    private let panel: NSPanel
    private let heard = NSTextField(labelWithString: "")
    private let picked = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let dot = NSView()
    let meter = LevelMeter()
    private var hideWork: DispatchWorkItem?
    private let width: CGFloat = 460
    var position: Position = .top
    /// Text shown right now, for self-tests.
    private(set) var current = (heard: "", picked: "", meta: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 78),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView(frame: panel.contentView!.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        heard.font = .systemFont(ofSize: 14, weight: .semibold)
        heard.lineBreakMode = .byTruncatingTail
        picked.font = .systemFont(ofSize: 12.5)
        picked.textColor = .secondaryLabelColor
        picked.maximumNumberOfLines = 5
        meta.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        meta.textColor = .tertiaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meter.isHidden = true
        [dot, heard, picked, meta, meter].forEach { fx.addSubview($0) }
    }

    private func layout() {
        let pad: CGFloat = 14, textX: CGFloat = 30, textW = width - textX - pad
        let meterW: CGFloat = meter.isHidden ? 0 : 96
        picked.preferredMaxLayoutWidth = textW
        let pickedH = picked.stringValue.isEmpty ? 0 : ceil(picked.sizeThatFits(NSSize(width: textW, height: 200)).height)
        let metaH: CGFloat = meta.stringValue.isEmpty ? 0 : 16
        let height = pad + 18 + (pickedH > 0 ? 4 + pickedH : 0) + (metaH > 0 ? 5 + metaH : 0) + pad - 2
        var y = height - pad - 18
        heard.frame = NSRect(x: textX, y: y, width: textW - meterW - (meterW > 0 ? 8 : 0), height: 18)
        dot.frame = NSRect(x: 14, y: y + 5, width: 8, height: 8)
        meter.frame = NSRect(x: width - pad - meterW, y: y + 1, width: meterW, height: 16)
        if pickedH > 0 { y -= 4 + pickedH; picked.frame = NSRect(x: textX, y: y, width: textW, height: pickedH) }
        picked.isHidden = pickedH == 0
        if metaH > 0 { y -= 5 + metaH; meta.frame = NSRect(x: textX, y: y, width: textW, height: metaH) }
        meta.isHidden = metaH == 0
        var f = panel.frame
        f.size = NSSize(width: width, height: height)
        panel.setFrame(f, display: true)
        place()
    }

    private func place() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let y = position == .top ? f.maxY - panel.frame.height - 12 : f.minY + 24
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: y))
    }

    func show(heard h: String, picked p: String = "", meta m: String = "", color: NSColor, autoHide: TimeInterval? = nil,
              listening: Bool = false) {
        hideWork?.cancel()
        heard.stringValue = h
        picked.stringValue = p
        meta.stringValue = m
        current = (h, p, m)
        dot.layer?.backgroundColor = color.cgColor
        if listening && meter.isHidden { meter.reset() }
        meter.isHidden = !listening
        meter.color = color
        layout()
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        if let t = autoHide {
            let w = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self?.panel.animator().alphaValue = 0 },
                                                     completionHandler: { self?.panel.orderOut(nil) })
            }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    func level(_ peak: Float) { if !meter.isHidden { meter.push(peak) } }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }
}

// MARK: - Sounds

enum Sounds {
    static var enabled = true
    private static func play(_ name: String, volume: Float) {
        guard enabled, let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }
    static func listen() { play("Tink", volume: 0.25) }
    static func success() { play("Pop", volume: 0.2) }
    static func failure() { play("Basso", volume: 0.25) }
    static func ask() { play("Morse", volume: 0.25) }
}
