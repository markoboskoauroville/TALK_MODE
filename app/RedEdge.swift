// RedEdge.swift (v12). Marko, 15.11.2026: "when you do space mode, put the red edge, same as on Sony camera ... red,
// half transparent, soft vignette, but not too soft ... so I understand I'm in space mode."
// Sony's REC frame: a solid red border with a short soft falloff inside, not a wide glow. Here: 7 pt border at 70 %, then
// 30 pt falling from 38 % to nothing. One click-through window per screen, on every Space, above full-screen apps;
// removed the instant Space Mode's `on` turns false (every exit path goes through it).
import AppKit

final class RedEdgeView: NSView {
    static let border: CGFloat = 7, fall: CGFloat = 30
    override var isFlipped: Bool { false }
    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        let red = CGColor(red: 1.0, green: 0.12, blue: 0.10, alpha: 1)
        // the soft inner falloff: four gradients from each edge inwards
        let cs = CGColorSpaceCreateDeviceRGB()
        let g = CGGradient(colorsSpace: cs, colors: [red.copy(alpha: 0.38)!, red.copy(alpha: 0.12)!, red.copy(alpha: 0)!] as CFArray, locations: [0, 0.45, 1])!
        let b = Self.border, f = Self.fall
        func strip(_ rect: NSRect, _ a: CGPoint, _ z: CGPoint) {
            c.saveGState(); c.clip(to: rect); c.drawLinearGradient(g, start: a, end: z, options: []); c.restoreGState()
        }
        strip(NSRect(x: r.minX, y: r.minY + b, width: r.width, height: f), CGPoint(x: 0, y: r.minY + b), CGPoint(x: 0, y: r.minY + b + f))
        strip(NSRect(x: r.minX, y: r.maxY - b - f, width: r.width, height: f), CGPoint(x: 0, y: r.maxY - b), CGPoint(x: 0, y: r.maxY - b - f))
        strip(NSRect(x: r.minX + b, y: r.minY, width: f, height: r.height), CGPoint(x: r.minX + b, y: 0), CGPoint(x: r.minX + b + f, y: 0))
        strip(NSRect(x: r.maxX - b - f, y: r.minY, width: f, height: r.height), CGPoint(x: r.maxX - b, y: 0), CGPoint(x: r.maxX - b - f, y: 0))
        // the solid border
        c.setFillColor(red.copy(alpha: 0.70)!)
        c.fill(NSRect(x: r.minX, y: r.minY, width: r.width, height: b)); c.fill(NSRect(x: r.minX, y: r.maxY - b, width: r.width, height: b))
        c.fill(NSRect(x: r.minX, y: r.minY, width: b, height: r.height)); c.fill(NSRect(x: r.maxX - b, y: r.minY, width: b, height: r.height))
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
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.titleVisibility = .hidden   // borderless overlay: no title at all
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = RedEdgeView(frame: NSRect(origin: .zero, size: s.frame.size))
            w.setFrame(s.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        if observer == nil {      // a screen plugged in or out while Space Mode is on: redraw for the new set
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                if !windows.isEmpty { show() } }
        }
    }

    private static func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// --edge-shot f.png --size WxH: the overlay drawn into a picture (over mid grey, to show the transparency)
    static func shot(_ path: String, _ w: Int, _ h: Int) {
        let v = RedEdgeView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("edge shot \(path)")
    }
}
