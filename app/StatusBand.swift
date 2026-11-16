// StatusBand.swift (v16). Marko, 16.11.2026: "I need to have some status line actually what's going on. Not only in UI, it needs
// to be always present ... right on the menu bar ... the same font and the same style as our voice to text and the same VU meter".
// The same look as Voice to Text (Mantra)'s display (BandField in MANTRA_VOICE_TO_TEXT mac/Sources/Pill.swift, v28-v35): monospaced
// semibold 9.5 pt words on a 55 % black rounded band, 16 pt wider than the words, and under it the hairline VU meter (2 pt rounded
// track at 18 %, green, orange above -12 dB, red above -3 dB, floor -54 dB, a peak hold that falls back slowly; the microphone is
// mono = ONE bar, no L/R labels: MANTRA_MANIFEST vu-meter-mono-stereo.md). One mark more: a small padlock left of the word while
// Space Bar Mode holds Macro Recorder's lock ("keyboard and mouse are off"), so he sees why other automation waits.
// Kept as its own file so Voice to Text can adopt it as the shared module at its next update (one module everywhere; Voice to
// Text's behaviour is not changed now).
import AppKit

final class StatusBand: NSView {
    static let floorDB: Float = -54
    var word = "" { didSet { if word != oldValue { needsDisplay = true } } }
    var wordColor: NSColor = .white { didSet { needsDisplay = true } }
    var locked = false { didSet { if locked != oldValue { needsDisplay = true } } }
    var meterDB: Float? {
        didSet {
            if let db = meterDB { peak = max(db, peak - 0.35) } else { peak = StatusBand.floorDB }
            needsDisplay = true
        }
    }
    private var peak: Float = StatusBand.floorDB
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }      // the status item's button takes the click

    private var font: NSFont { .monospacedSystemFont(ofSize: 9.5, weight: .semibold) }
    var wantedWidth: CGFloat {
        let t = (word as NSString).size(withAttributes: [.font: font]).width
        return ceil(t) + 16 + (locked ? 12 : 0)
    }
    private func x(_ db: Float, _ track: NSRect) -> CGFloat {
        track.minX + CGFloat(max(0, min(1, (db - StatusBand.floorDB) / -StatusBand.floorDB))) * track.width
    }
    override func draw(_ r: NSRect) {
        guard !word.isEmpty else { return }
        let band = bounds
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
        var left: CGFloat = 8
        if locked, let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "keyboard and mouse are off") {
            let cfg = img.withSymbolConfiguration(.init(pointSize: 8, weight: .bold))?.tinted(NSColor(red: 0.91, green: 0.45, blue: 0.23, alpha: 1))
            let s = cfg?.size ?? .zero
            cfg?.draw(in: NSRect(x: 7, y: (band.height - 3 - s.height) / 2 + 1, width: s.width, height: s.height))
            left = 7 + s.width + 3
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: wordColor]
        let sz = (word as NSString).size(withAttributes: attrs)
        (word as NSString).draw(at: NSPoint(x: left, y: (band.height - 3 - sz.height) / 2), withAttributes: attrs)
        // the hairline meter on the bottom edge (flipped view: bottom = maxY)
        let track = NSRect(x: band.minX + 7, y: band.maxY - 3, width: max(0, band.width - 14), height: 2)
        guard track.width > 4 else { return }
        NSColor(white: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        guard let db = meterDB, db > StatusBand.floorDB else { return }
        let end = x(db, track), x12 = x(-12, track), x3 = x(-3, track)
        let green = NSColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1), red = NSColor(red: 1, green: 0.35, blue: 0.31, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: end - track.minX, height: track.height), xRadius: 1, yRadius: 1).addClip()
        green.setFill(); NSRect(x: track.minX, y: track.minY, width: min(end, x12) - track.minX, height: track.height).fill()
        if end > x12 { NSColor.orange.setFill(); NSRect(x: x12, y: track.minY, width: min(end, x3) - x12, height: track.height).fill() }
        if end > x3 { red.setFill(); NSRect(x: x3, y: track.minY, width: end - x3, height: track.height).fill() }
        NSGraphicsContext.restoreGraphicsState()
        let px = x(peak, track)
        (peak > -3 ? red : peak > -12 ? NSColor.orange : green).setFill()
        NSRect(x: min(px, track.maxX - 2), y: track.minY, width: 2, height: track.height).fill()
    }
}

extension NSImage {
    func tinted(_ c: NSColor) -> NSImage {
        let i = NSImage(size: size, flipped: false) { r in self.draw(in: r); c.set(); r.fill(using: .sourceAtop); return true }
        return i
    }
}
