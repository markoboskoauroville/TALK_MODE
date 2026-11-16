// RedEdge.swift (v12, changed in v16). Marko, 15.11.2026: "when you do space mode, put the red edge ... so I understand I'm in
// space mode." Marko, 16.11.2026: "this red record frame ... is hiding the bar. Maybe we can just keep one red ... I was thinking
// we keep just the bottom line and the rest is going out." Now ONLY a red line (7 pt, 70 %, with the short soft falloff above it)
// along the BOTTOM edge of every screen: the overlay window is that strip alone, click-through, on every Space, above full-screen
// apps; the menu bar is never covered. Removed the instant Space Bar Mode's `on` turns false (every exit path goes through it).
import AppKit

final class RedEdgeView: NSView {
    static let border: CGFloat = 7, fall: CGFloat = 30
    static var stripHeight: CGFloat { border + fall }
    override var isFlipped: Bool { false }
    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        let red = CGColor(red: 1.0, green: 0.12, blue: 0.10, alpha: 1)
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [red.copy(alpha: 0.38)!, red.copy(alpha: 0.12)!, red.copy(alpha: 0)!] as CFArray, locations: [0, 0.45, 1])!
        let b = Self.border, f = Self.fall
        c.saveGState(); c.clip(to: NSRect(x: r.minX, y: r.minY + b, width: r.width, height: f))
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY + b), end: CGPoint(x: 0, y: r.minY + b + f), options: []); c.restoreGState()
        c.setFillColor(red.copy(alpha: 0.70)!)
        c.fill(NSRect(x: r.minX, y: r.minY, width: r.width, height: b))
    }
}

enum RedEdge {
    private static var windows: [NSWindow] = []
    private static var observer: Any?

    static func set(_ on: Bool) {
        DispatchQueue.main.async { on ? show() : hide() }
    }

    private static func show() {
        hide()
        for s in NSScreen.screens {
            let h = RedEdgeView.stripHeight
            let strip = NSRect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: h)
            let w = NSWindow(contentRect: strip, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.titleVisibility = .hidden
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = RedEdgeView(frame: NSRect(origin: .zero, size: strip.size))
            w.setFrame(strip, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        if observer == nil {      // a screen plugged in or out while Space Bar Mode is on: redraw for the new set
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                if !windows.isEmpty { show() } }
        }
    }

    private static func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// --edge-shot f.png --size WxH: the strip drawn at the bottom of a mid grey picture (to show the transparency)
    static func shot(_ path: String, _ w: Int, _ h: Int) {
        let v = RedEdgeView(frame: NSRect(x: 0, y: 0, width: w, height: Int(RedEdgeView.stripHeight)))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: v.bounds.height))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("edge shot \(path)")
    }
}
