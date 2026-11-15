// WindowFit.swift (v12). Marko, 15.11.2026: "It going out of the screen and is just staying there ... make it understand
// when I leave it somewhere that nothing is going out of the display. It needs to adjust its height ... so I see the bottom
// ... especially when I change monitors, a different size, then it is falling out."
// The window is always fully inside the visible area (menu bar and Dock excluded) of the screen that holds most of it:
// after every move and resize, on screen changes, on wake, on launch. Smaller than its wished size = shrunk to fit; its
// minimum size shrinks too when the screen is smaller than that; the content scrolls as the last resort.
// The position is remembered per screen configuration (the set of screen sizes), so back on the BenQ it returns where it was.
import AppKit
import Foundation

enum WindowFit {
    /// the pure rule: the frame moved and, when needed, shrunk until it lies inside `visible`
    static func fit(_ f: NSRect, in visible: NSRect, minSize: NSSize) -> NSRect {
        var r = f
        let minW = min(minSize.width, visible.width), minH = min(minSize.height, visible.height)
        r.size.width = max(minW, min(r.width, visible.width))
        r.size.height = max(minH, min(r.height, visible.height))
        r.origin.x = max(visible.minX, min(r.origin.x, visible.maxX - r.width))
        r.origin.y = max(visible.minY, min(r.origin.y, visible.maxY - r.height))
        return r
    }

    /// the screen holding most of the frame (the nearest one when it is wholly outside every screen)
    static func best(for f: NSRect, among rects: [NSRect]) -> Int {
        var bi = 0, ba: CGFloat = -1
        for (i, s) in rects.enumerated() {
            let x = f.intersection(s)
            let a = x.isNull ? 0 : x.width * x.height
            if a > ba { ba = a; bi = i }
        }
        if ba > 0 { return bi }
        let c = NSPoint(x: f.midX, y: f.midY)
        var bd = CGFloat.greatestFiniteMagnitude
        for (i, s) in rects.enumerated() {
            let d = hypot(max(s.minX - c.x, 0, c.x - s.maxX), max(s.minY - c.y, 0, c.y - s.maxY))
            if d < bd { bd = d; bi = i }
        }
        return bi
    }

    /// the wished minimum size of the window
    static let wishedMin = NSSize(width: 720, height: 500)

    /// the screen configuration as text: every screen's size and place, sorted
    static func signature(_ frames: [NSRect]) -> String {
        frames.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" }.sorted().joined(separator: "|")
    }

    static var currentSignature: String { signature(NSScreen.screens.map(\.frame)) }
    private static let key = "frameBySetup"

    static func remember(_ f: NSRect) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        d[currentSignature] = NSStringFromRect(f)
        UserDefaults.standard.set(d, forKey: key)
    }
    static func remembered() -> NSRect? {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return d[currentSignature].map { NSRectFromString($0) }.flatMap { $0.width > 0 ? $0 : nil }
    }

    /// constrain a real window now; `useRemembered` = take this configuration's remembered frame first (screen changes, launch)
    static func apply(_ w: NSWindow, useRemembered: Bool = false) {
        guard !w.styleMask.contains(.fullScreen), !NSScreen.screens.isEmpty else { return }
        var f = w.frame
        if useRemembered, let r = remembered() { f = r }
        let vis = NSScreen.screens.map(\.visibleFrame)
        let v = vis[best(for: f, among: NSScreen.screens.map(\.frame))]
        let m = NSSize(width: min(wishedMin.width, v.width), height: min(wishedMin.height, v.height))
        if w.contentMinSize != m { w.contentMinSize = m }
        let n = fit(f, in: v, minSize: m)
        if n != w.frame { w.setFrame(n, display: true) }
    }
}
