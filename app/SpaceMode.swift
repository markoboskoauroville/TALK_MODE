// SpaceMode.swift (v11, 15.11.2026): SPACE MODE. Marko: "space mode ... my keyboard and mouse outputs are disabled
// completely ... I press space and you do all the actions. We are just interacting to the voice. So space reacts wherever
// is the focus. It triggers the recording and you are answering to me." And: "you need to also put this blocking banner you
// are using when macro is running, so I can also press and take over. And I can also in voice tell you, okay, go out of
// this mode."
//
// Two halves, one module each:
// - the mouse and the banner are Macro Recorder (Mantra)'s ONE input lock (127.0.0.1:8829, v28+): POST /lock with
//   keys "pass" (the keyboard is ours), plain_bar (our sentence on its bar), blob false, esc_hold 2, beat 5. Its TAKE OVER
//   ends Space Mode. It is also the watchdog: no POST /beat for 5 s (Talk Mode hangs) or Talk Mode gone = lifted.
// - the keyboard is this file's tap at the HID level (before every session tap): every key is swallowed; Space (no ⌘ ⌃ ⌥)
//   starts a take, the second Space sends it; Esc Esc (twice within 1 s) ends Space Mode, one Esc while dictating cancels the take. The tap runs on the main run loop, so a
//   hang makes macOS switch it off by itself (tapDisabledByTimeout): the keyboard is never held by a frozen app.
// Ways out, never a lockout: TAKE OVER on the banner, Esc Esc, the voice ("space mode off", "go out of this mode",
// "I want my keyboard back", "isključi space mode"), the switch, talkmode://space-off, the watchdog, quitting the app.
import AppKit
import ApplicationServices

final class SpaceMode: ObservableObject {
    static let shared = SpaceMode()
    static let owner = "talkmode-space"
    static let banner = "SPACE BAR MODE — keyboard and mouse are off · SPACE talks · Esc Esc = exit (Esc once cancels a take) · or press TAKE OVER"
    static let macroAPI = "http://127.0.0.1:8829"
    static let MACRO_MARK: Int64 = 0x4D41_4352_4F4B        // Macro Recorder's own events pass every lock

    @Published private(set) var on = false { didSet { if on != oldValue { RedEdge.set(on) } } }
    @Published private(set) var starting = false
    @Published var note = ""
    @Published private(set) var trusted = AXIsProcessTrusted()

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var ticker: Timer?
    private var autoOff: Timer?
    private var escSince: Date?            // (unused since v15)
    private var lastEsc: Date?              // v15: the first Esc of an Esc Esc
    private var ticks = 0
    private var beatMisses = 0
    private var beating = false

    private init() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            let now = AXIsProcessTrusted()
            if self?.trusted != now { self?.trusted = now }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    static func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    // ------------------------------------------------------------ Macro Recorder's lock
    static func macro(_ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 1.5) -> [String: Any]? {
        guard let url = URL(string: macroAPI + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        if let b = body {
            r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: r) { d, _, _ in
            if let d { out = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return out
    }

    // ------------------------------------------------------------ on
    /// testSeconds: the self-disabling test (talkmode://space-test): Space Mode turns itself off after that many seconds.
    func enable(testSeconds: Int? = nil) {
        guard !on, !starting else { return }
        trusted = AXIsProcessTrusted()
        guard trusted else {
            // the system asks Marko (never answered for him); PERMISSIONS stays amber top right until it is allowed
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            note = "Space Bar Mode needs Accessibility for Talk Mode (Mantra): System Settings › Privacy & Security › Accessibility"
            return
        }
        starting = true; note = "Space Bar Mode: asking Macro Recorder for the lock…"
        DispatchQueue.global().async {
            let st = SpaceMode.macro("/status")
            var why = ""
            var ok = false
            if st == nil { why = "Macro Recorder (Mantra) is not running: Space Bar Mode uses its input lock and its TAKE OVER" }
            else if (st?["version"] as? Int ?? 0) < 28 { why = "Space Bar Mode needs Macro Recorder (Mantra) v28 or newer (this Mac has v\(st?["version"] as? Int ?? 0))" }
            else if (st?["lock"] as? String ?? "off") != "off" { why = "the input lock is busy (\(st?["lock"] as? String ?? "")): try again in a moment" }
            else {
                let r = SpaceMode.macro("/lock", ["owner": SpaceMode.owner, "text": SpaceMode.banner, "seconds": 0, "pid": Int(getpid()),
                                                  "restore": false, "keys": "pass", "plain_bar": true, "blob": false, "esc_hold": 5, "beat": 5])
                ok = r?["ok"] as? Bool == true
                if !ok { why = "the input lock did not come on: " + (r?["error"] as? String ?? "no answer") }
            }
            DispatchQueue.main.async {
                self.starting = false
                guard ok else { self.note = why; return }
                guard self.installTap() else {
                    _ = SpaceMode.macro("/unlock", ["owner": SpaceMode.owner])
                    self.note = "the keyboard tap did not start (Accessibility for Talk Mode)"; return
                }
                self.on = true; self.note = ""; self.escSince = nil; self.lastEsc = nil; self.beatMisses = 0; self.ticks = 0
                self.ticker?.invalidate()
                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(t, forMode: .common); self.ticker = t
                if let s = testSeconds {
                    let a = Timer(timeInterval: Double(s), repeats: false) { [weak self] _ in self?.disable("test over") }
                    RunLoop.main.add(a, forMode: .common); self.autoOff = a
                }
                Voice.say(testSeconds == nil ? "Space mode on. Press space to talk." : "Space mode test for \(testSeconds!) seconds.")
                Talk.shared.saveState(); App.shared.refreshStatusItem()
                NSLog("[Space] on (test %@)", testSeconds.map(String.init) ?? "no")
            }
        }
    }

    // ------------------------------------------------------------ off
    /// reason: switch, voice, escape, takeover, heartbeat, macro-gone, test over, quit
    func disable(_ reason: String, speak: Bool = true) {
        guard on else { return }
        on = false
        removeTap()
        ticker?.invalidate(); ticker = nil
        autoOff?.invalidate(); autoOff = nil
        escSince = nil
        let external = ["takeover", "escape-macro", "heartbeat", "holder-gone", "time", "macro-gone", "unlock"].contains(reason)
        if !external {
            if reason == "quit" { _ = SpaceMode.macro("/unlock", ["owner": SpaceMode.owner], timeout: 0.8) }
            else { DispatchQueue.global().async { _ = SpaceMode.macro("/unlock", ["owner": SpaceMode.owner]) } }
        }
        note = "Space Bar Mode off (" + reason + ")"
        if speak { Voice.say("Space mode off.") }
        Talk.shared.saveState(); App.shared.refreshStatusItem()
        NSLog("[Space] off: %@", reason)
    }

    func toggle() { on ? disable("switch") : enable() }

    /// 4 times a second: Escape held, and once a second the beat to Macro Recorder (its answer says whether the lock still holds)
    private func tick() {
        guard on else { return }
        if let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        ticks += 1
        guard ticks % 4 == 0, !beating else { return }
        beating = true
        DispatchQueue.global().async {
            let r = SpaceMode.macro("/beat", ["owner": SpaceMode.owner], timeout: 1)
            DispatchQueue.main.async {
                self.beating = false
                guard self.on else { return }
                guard let r else {
                    self.beatMisses += 1
                    if self.beatMisses >= 3 { self.disable("macro-gone") }     // its tap died with it: the keyboard comes back too
                    return
                }
                self.beatMisses = 0
                if r["ok"] as? Bool != true {
                    let e = r["ended"] as? String ?? ""
                    self.disable(e == "escape" ? "escape-macro" : (e.isEmpty ? "unlock" : e))
                }
            }
        }
    }

    // ------------------------------------------------------------ the keyboard tap (HID level, before every session tap)
    private func installTap() -> Bool {
        removeTap()
        var mask: CGEventMask = 0
        for t: CGEventType in [.keyDown, .keyUp, .flagsChanged] { mask |= 1 << t.rawValue }
        let cb: CGEventTapCallBack = { _, type, e, ref in
            let me = Unmanaged<SpaceMode>.fromOpaque(ref!).takeUnretainedValue()
            return me.filter(type, e)
        }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; tapSource = nil
    }

    /// nil swallows. Runs on the main thread.
    private func filter(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if on, let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        guard on else { return pass }
        if e.getIntegerValueField(.eventSourceUserData) == SpaceMode.MACRO_MARK { return pass }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let repeatKey = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if code == 53 {                                                    // v15: Esc cancels a take; Esc Esc (within 1 s) = out
            if type == .keyDown, !repeatKey {
                if Talk.shared.manual {                                    // dictating: one Esc cancels the take and does NOT count toward Esc Esc
                    lastEsc = nil
                    DispatchQueue.main.async { Talk.shared.cancelTake() }
                } else if let l = lastEsc, Date().timeIntervalSince(l) <= 1.0 {
                    lastEsc = nil
                    DispatchQueue.main.async { self.disable("escape") }
                } else { lastEsc = Date() }
            }
            return nil
        }
        if code == 49, type == .keyDown, !repeatKey,
           e.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            DispatchQueue.main.async { Talk.shared.spacePressed() }
            return nil
        }
        return nil                                                         // every other key: off
    }
}

/// Did he mean "leave Space Mode"? Words first (English and Croatian, misheard forms within one letter); short sentences
/// only, so a long message to Claude that mentions the mode is sent, not taken as the command.
enum SpaceExit {
    static func norm(_ s: String) -> [String] {
        let f = s.lowercased().folding(options: [.diacriticInsensitive], locale: nil).replacingOccurrences(of: "đ", with: "d")
        return f.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }
    static func near(_ w: String, _ list: [String]) -> Bool {
        list.contains { k in w == k || (k.count >= 4 && w.count >= 4 && lev(w, k) <= 1) }
    }
    static func lev(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var prev = d[0]; d[0] = i
            for j in 1...y.count {
                let t = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = t
            }
        }
        return d[y.count]
    }

    static let spaceWords = ["space", "spaces", "spejs", "spejz", "spice", "spacemode"]
    static let modeWords = ["mode", "mod", "moda", "modu", "modus", "nacin", "rezim", "spacemode"]
    static let exitWords = ["off", "out", "exit", "leave", "stop", "end", "quit", "close", "disable", "finish", "cancel", "escape",
                            "iskljuci", "ugasi", "izadi", "izlaz", "van", "prekini", "zaustavi", "makni", "gotovo", "kraj"]
    static let handWords = ["keyboard", "mouse", "tipkovnicu", "tipkovnica", "mis", "misa"]
    static let backWords = ["back", "vrati", "vratiti", "return"]

    static func matches(_ text: String) -> Bool {
        let w = norm(text)
        guard !w.isEmpty, w.count <= 12 else { return false }
        let space = w.contains { near($0, spaceWords) }
        let mode = w.contains { modeWords.contains($0) }
        let exit = w.contains { exitWords.contains($0) || near($0, ["disable", "escape", "iskljuci", "zaustavi"]) }
        let hands = w.contains { near($0, handWords) }
        let back = w.contains { backWords.contains($0) }
        if !space && w.contains(where: { ["talk", "typing", "tipkanje"].contains($0) }) { return false }   // "talk mode off" is typing mode
        let this = w.contains { ["this", "that", "the", "ovog", "ovoga", "tog", "toga", "ovaj"].contains($0) }
        if space && mode && (exit || w.last == "of") { return true }            // "space mode off", "exit space mode", "izađi iz space moda"
        if mode && exit && this { return true }             // "go out of this mode", "izađi iz ovog moda"
        if space && exit && w.count <= 5 { return true }    // "space off", "isključi space"
        if hands && (back || exit) { return true }          // "I want my keyboard back", "vrati mi tipkovnicu"
        return false
    }
}
