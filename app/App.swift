// Talk Mode (Mantra): a real conversation with a Claude Code session, hands free. Marko talks and pauses; his words are
// written into the chosen session (iTerm2, `write text`, then Return); Claude answers aloud (langsay through MANTRA_VOICE);
// while the voice talks Talk Mode does not listen; then it listens again. The window says where we are in words big
// enough to read from the camera, three metres away: LISTENING · HEARD: "…" · CLAUDE IS THINKING · SPEAKING.
// Marko, 15.11.2026: "when I say real time talk mode, you are waiting for me to pause, then you say something and we kind
// of do this thing together ... I'm not in front of computer I'm in front of the camera".
//
// Switch: say "real time talk mode" / "talk mode on", and "typing mode" / "talk mode off"; ⌃⌥T anywhere; the menu bar
// item; `open -g talkmode://on|off|toggle|repeat|show`. "Say that again" plays the last answer again (/speak/replay).
// Debug path (no microphone, no window): TalkMode --test-wav FILE --to-tty /dev/ttysNNN [--lang en] [--pause 1.3]
import AppKit
import Carbon
import SwiftUI

let VERSION = 1
let APP_NAME = "Talk Mode (Mantra)"

enum Ink {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let ground = hex(0x0B0B0D)
    static let line = hex(0x2E2E33)
    static let text = hex(0xECECEC)
    static let dim = hex(0x8E8E96)
    static let green = hex(0x33D17A)
    static let grey = hex(0x7A8087)
    static let amber = hex(0xF0A030)
    static let red = hex(0xFF5A4F)
    static let violet = hex(0x9B8CFF)
    static let orange = hex(0xE8743B)

    static func of(_ s: TalkState) -> Color {
        switch s {
        case .listening: return green
        case .hearing: return hex(0x7CF0A8)
        case .writing: return amber
        case .thinking: return violet
        case .speaking: return orange
        case .typing: return grey
        case .recording, .voiceDown, .noMic: return red
        case .noTarget: return amber
        }
    }
}

struct PressHover: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hot = false
    func body(content: Content) -> some View {
        let on = hot && enabled
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(on ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(on ? 0.55 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: on)
            .onHover { inside in hot = inside
                if enabled { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
    }
}

extension View {
    func pressHover() -> some View { modifier(PressHover()) }
    func axButton(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
    /// a word that is a button: tap, hover highlight, Accessibility button
    func word(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        self.pressHover().contentShape(Rectangle()).onTapGesture(perform: action).axButton(label, id: id, value: value, action)
    }
}

/// words laid out in rows that wrap: nothing is cut at the minimum width
struct Flow: Layout {
    var spacing: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { y += row + 8; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); maxW = max(maxW, x - spacing)
        }
        return CGSize(width: min(w, maxW), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { y += row + 8; x = b.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

struct Hairline: View { var body: some View { Rectangle().fill(Ink.line).frame(height: 1) } }

/// a horizontal hairline that fills: the level of the microphone
struct Fill: View {
    let value: Double
    var color: Color = Ink.green
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Ink.line)
                Rectangle().fill(color).frame(width: g.size.width * max(0, min(1, value)))
            }
        }.frame(height: 1)
    }
}

/// the round number of a workflow step
struct StepNumber: View {
    let n: Int
    var body: some View {
        Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Ink.text)
            .frame(width: 24, height: 24).overlay(Circle().stroke(Ink.dim, lineWidth: 1))
    }
}

struct Cell<V: View>: View {
    let label: String
    @ViewBuilder var value: V
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.dim)
            value.font(.system(size: 15, weight: .bold, design: .monospaced))
        }
    }
}

// ---------------------------------------------------------------- the window
struct TopRow: View {
    @AppStorage("onTop") private var onTop = false
    var body: some View {
        ZStack {
            (Text("Talk Mode").fontWeight(.bold) + Text(" (Mantra)").fontWeight(.regular))
                .font(.system(size: 15)).foregroundStyle(Ink.text)
            HStack(spacing: 10) {
                Spacer().frame(width: 64)
                Text("ON").foregroundStyle(Ink.green)
                Text("OFF").foregroundStyle(Ink.grey).word("Off, quit Talk Mode", id: "off") { DispatchQueue.main.async { NSApp.terminate(nil) } }
                Spacer()
                Text("v\(VERSION)").foregroundStyle(Ink.dim)
                Text("TOP").foregroundStyle(onTop ? Ink.green : Ink.grey)
                    .word("Top", id: "top", value: onTop ? "on" : "off") { onTop.toggle(); TopRow.float(onTop) }
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 22, height: 22)
                    .word("Close window", id: "close") { App.shared.window?.performClose(nil) }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .frame(height: 32)
        .onAppear { DispatchQueue.main.async { TopRow.float(onTop) } }
    }
    static func float(_ on: Bool) { App.shared.window?.level = on ? .floating : .normal; App.shared.enforceOneTitle()
    }
}

struct Root: View {
    @ObservedObject var talk = Talk.shared

    /// a long sentence keeps its last 220 characters on screen (the words are all in the session)
    func shown(_ s: String) -> String { s.count > 220 ? "…" + s.suffix(220) : s }

    var body: some View {
        VStack(spacing: 0) {
            TopRow(); Hairline()
            GeometryReader { g in
                let big = max(40, min(g.size.width / 7.5, g.size.height / 3.4, 170))
                VStack(spacing: big * 0.22) {
                    Spacer(minLength: 0)
                    Text(talk.state.word)
                        .font(.system(size: big, weight: .black, design: .rounded))
                        .foregroundStyle(Ink.of(talk.state))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("state")
                    if talk.on && !talk.heard.isEmpty {
                        (Text("HEARD: ").foregroundColor(Ink.dim) + Text("“\(shown(talk.heard))”").foregroundColor(Ink.text))
                            .font(.system(size: max(18, big * (talk.heard.count > 90 ? 0.24 : 0.36)), weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("heard")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .frame(width: g.size.width, height: g.size.height)
            }
            .frame(minHeight: 220)
            Hairline()
            steps.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Ink.ground)
        .foregroundStyle(Ink.text)
    }

    var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Flow(spacing: 26) {
                HStack(spacing: 8) {
                    StepNumber(n: 1)
                    Cell(label: "TALK TO") {
                        Menu {
                            ForEach(talk.sessions) { s in Button(s.name) { talk.choose(s) } }
                            Divider()
                            Button("Look for sessions again") { talk.refreshSessions() }
                        } label: { Text(talk.target?.name ?? "CHOOSE THE SESSION").foregroundStyle(talk.target == nil ? Ink.amber : Ink.text) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Talk to session")
                    }
                }
                HStack(spacing: 8) {
                    StepNumber(n: 2)
                    Cell(label: "MICROPHONE") {
                        VStack(alignment: .leading, spacing: 4) {
                            Menu {
                                ForEach(talk.devices, id: \.self) { d in Button(d.name) { talk.choose(d) } }
                                Divider()
                                Button("Look for microphones again") { talk.refreshDevices() }
                            } label: { Text(talk.device?.name ?? "NONE").foregroundStyle(talk.device == nil ? Ink.red : Ink.text) }
                            .menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Microphone")
                            Fill(value: Double((talk.levelDB + 70) / 60)).frame(width: 160)
                        }
                    }
                }
                HStack(spacing: 8) {
                    StepNumber(n: 3)
                    Cell(label: "TALK MODE") {
                        HStack(spacing: 6) {
                            Text("ON").foregroundStyle(talk.on ? Ink.green : Ink.grey)
                                .word("Talk mode on", id: "talk-on", value: talk.on ? "on" : "off") { if !talk.on { talk.setOn(true) } }
                            Text("|").foregroundStyle(Ink.dim)
                            Text("TYPING").foregroundStyle(talk.on ? Ink.grey : Ink.text)
                                .word("Typing mode", id: "talk-off", value: talk.on ? "off" : "on") { if talk.on { talk.setOn(false) } }
                        }
                    }
                }
            }
            Hairline()
            Flow(spacing: 26) {
                Cell(label: "LANGUAGE") {
                    HStack(spacing: 6) {
                        Text("EN").foregroundStyle(talk.lang == "en" ? Ink.green : Ink.grey).word("English", id: "lang-en", value: talk.lang == "en" ? "on" : "off") { talk.lang = "en" }
                        Text("|").foregroundStyle(Ink.dim)
                        Text("HR").foregroundStyle(talk.lang == "hr" ? Ink.green : Ink.grey).word("Croatian", id: "lang-hr", value: talk.lang == "hr" ? "on" : "off") { talk.lang = "hr" }
                    }
                }
                Cell(label: "PAUSE THAT ENDS A SENTENCE") {
                    HStack(spacing: 6) {
                        Text("−").foregroundStyle(Ink.grey).word("Shorter pause", id: "pause-less") { talk.pause = max(0.6, ((talk.pause - 0.1) * 10).rounded() / 10) }
                        Text(String(format: "%.1f sec", talk.pause)).fixedSize()
                        Text("+").foregroundStyle(Ink.grey).word("Longer pause", id: "pause-more") { talk.pause = min(4, ((talk.pause + 0.1) * 10).rounded() / 10) }
                    }
                }
                Cell(label: "SHORTER IS A NOISE") {
                    HStack(spacing: 6) {
                        Text("−").foregroundStyle(Ink.grey).word("Shorter noise limit", id: "noise-less") { talk.minLength = max(0.2, ((talk.minLength - 0.1) * 10).rounded() / 10) }
                        Text(String(format: "%.1f sec", talk.minLength)).fixedSize()
                        Text("+").foregroundStyle(Ink.grey).word("Longer noise limit", id: "noise-more") { talk.minLength = min(2, ((talk.minLength + 0.1) * 10).rounded() / 10) }
                    }
                }
                Cell(label: "LAST ANSWER") {
                    Text("SAY IT AGAIN").foregroundStyle(Ink.text).word("Say the last answer again", id: "repeat") { talk.repeatLast() }
                }
                Cell(label: "SWITCH") { Text("⌃⌥T").foregroundStyle(Ink.dim).fixedSize() }
            }
            if !talk.note.isEmpty {
                Text(talk.note).font(.system(size: 13)).foregroundStyle(Ink.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// ---------------------------------------------------------------- the global shortcut ⌃⌥T
enum HotKey {
    static var ref: EventHotKeyRef?
    static var action: (() -> Void)?
    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x544B4D44), id: 1)       // "TKMD"
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// ---------------------------------------------------------------- the app
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static let shared = App()
    var window: NSWindow?
    private var status: NSStatusItem?
    private var activity: NSObjectProtocol?
    private var observer: Any?

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        mainMenu()
        makeStatusItem()
        makeWindow()
        HotKey.action = { Talk.shared.toggle() }
        HotKey.register()
        // listening goes on with the window behind others (no App Nap)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "listening for Marko")
        Talk.shared.start()
        observer = Talk.shared.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.refreshStatusItem() } }
        Updater.checkAtStart()
    }

    @objc func handleURL(_ e: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = e.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URL(string: s) else { return }
        let what = (u.host ?? u.path).lowercased()
        switch what {
        case "on": Talk.shared.setOn(true)
        case "off": Talk.shared.setOn(false)
        case "toggle": Talk.shared.toggle()
        case "repeat": Talk.shared.repeatLast()
        case "show": showWindow()
        default: NSLog("[Talk] unknown url %@", s)
        }
    }

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = APP_NAME
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.backgroundColor = NSColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)
        w.contentMinSize = NSSize(width: 720, height: 500)
        w.contentView = NSHostingView(rootView: Root())
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("TalkModeMain")
        window = w
        enforceOneTitle(w)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.enforceOneTitle(w) }
    }

    func showWindow() {
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ONE TITLE ONLY (Marko 15.11.2026). The app draws its own title (TopRow); the system title stays hidden in every
    /// state: creation, key, resize, full screen, TOP. MANTRA_MANIFEST modules/one-title-only.md.
    func enforceOneTitle(_ w: NSWindow? = nil) {
        guard let w = w ?? window else { return }
        w.title = APP_NAME
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        func walk(_ v: NSView) {
            if v === w.contentView { return }
            if let t = v as? NSTextField, t.stringValue == APP_NAME { t.isHidden = true; t.alphaValue = 0 }
            v.subviews.forEach(walk)
        }
        if let frame = w.contentView?.superview { walk(frame) }
    }
    func windowDidBecomeKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResignKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResize(_ n: Notification) { enforceOneTitle() }
    func windowDidEnterFullScreen(_ n: Notification) { enforceOneTitle() }
    func windowDidExitFullScreen(_ n: Notification) { enforceOneTitle() }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }   // ✕ closes the window, listening goes on
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }

    // ------------------------------------------------------------ the menu bar item
    private func makeStatusItem() {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let m = NSMenu(); m.delegate = self
        s.menu = m
        s.button?.setAccessibilityLabel("Talk Mode")
        status = s
        refreshStatusItem()
    }

    func refreshStatusItem() {
        let t = Talk.shared
        let colour: NSColor = t.on ? NSColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1) : .secondaryLabelColor
        status?.button?.attributedTitle = NSAttributedString(string: t.on ? "TALK" : "talk", attributes: [
            .foregroundColor: colour, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)])
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        let t = Talk.shared
        m.removeAllItems()
        m.addItem(withTitle: t.state.word, action: nil, keyEquivalent: "")
        m.addItem(.separator())
        let toggle = NSMenuItem(title: t.on ? "Typing Mode (talk mode off)" : "Talk Mode On", action: #selector(menuToggle), keyEquivalent: "t")
        toggle.keyEquivalentModifierMask = [.control, .option]; toggle.target = self; m.addItem(toggle)
        let again = NSMenuItem(title: "Say the Last Answer Again", action: #selector(menuRepeat), keyEquivalent: ""); again.target = self; m.addItem(again)
        m.addItem(.separator())
        let ses = NSMenuItem(title: "Talk To", action: nil, keyEquivalent: ""), sm = NSMenu()
        for s in t.sessions {
            let i = NSMenuItem(title: s.name, action: #selector(menuSession(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.id; i.state = s.id == t.target?.id ? .on : .off; sm.addItem(i)
        }
        ses.submenu = sm; m.addItem(ses)
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: ""), mm = NSMenu()
        for d in t.devices {
            let i = NSMenuItem(title: d.name, action: #selector(menuMic(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = d.uid; i.state = d.uid == t.device?.uid ? .on : .off; mm.addItem(i)
        }
        mic.submenu = mm; m.addItem(mic)
        let lang = NSMenuItem(title: "Language", action: nil, keyEquivalent: ""), lm = NSMenu()
        for (code, name) in [("en", "English"), ("hr", "Croatian")] {
            let i = NSMenuItem(title: name, action: #selector(menuLang(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = code; i.state = t.lang == code ? .on : .off; lm.addItem(i)
        }
        lang.submenu = lm; m.addItem(lang)
        m.addItem(.separator())
        let show = NSMenuItem(title: "Show Window", action: #selector(menuShow), keyEquivalent: ""); show.target = self; m.addItem(show)
        m.addItem(withTitle: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        t.refreshSessions()
    }

    @objc func menuToggle() { Talk.shared.toggle() }
    @objc func menuRepeat() { Talk.shared.repeatLast() }
    @objc func menuShow() { showWindow() }
    @objc func menuSession(_ i: NSMenuItem) {
        if let id = i.representedObject as? String, let s = Talk.shared.sessions.first(where: { $0.id == id }) { Talk.shared.choose(s) }
    }
    @objc func menuMic(_ i: NSMenuItem) {
        if let uid = i.representedObject as? String, let d = Talk.shared.devices.first(where: { $0.uid == uid }) { Talk.shared.choose(d) }
    }
    @objc func menuLang(_ i: NSMenuItem) { if let c = i.representedObject as? String { Talk.shared.lang = c } }

    private func mainMenu() {
        let m = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; m.addItem(appItem)
        let talkItem = NSMenuItem(), talkMenu = NSMenu(title: "Talk")
        let t = NSMenuItem(title: "Talk Mode On / Typing Mode", action: #selector(menuToggle), keyEquivalent: "t")
        t.keyEquivalentModifierMask = [.control, .option]; t.target = self; talkMenu.addItem(t)
        let r = NSMenuItem(title: "Say the Last Answer Again", action: #selector(menuRepeat), keyEquivalent: "r")
        r.target = self; talkMenu.addItem(r)
        talkItem.submenu = talkMenu; m.addItem(talkItem)
        NSApp.mainMenu = m
    }
}

// ---------------------------------------------------------------- the debug path: a WAV instead of the microphone
/// TalkMode --test-wav FILE --to-tty /dev/ttysNNN [--lang en] [--pause 1.3] [--fast]
/// The file is fed in real time through the same gate, detector, ears (/hear), phrases and iTerm2 writer as the
/// microphone; every step is printed as one JSON line. Used to prove the road without a microphone permission.
enum Bench {
    static func out(_ j: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: j), let s = String(data: d, encoding: .utf8) { print(s); fflush(stdout) }
    }

    static func run(_ a: [String]) -> Int32 {
        func val(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        guard let path = val("--test-wav") else { return 2 }
        let lang = val("--lang") ?? "en"
        let realtime = !a.contains("--fast")
        var samples: [Float]
        do { samples = try WAV.load(path) } catch { out(["event": "error", "error": "\(error)"]); return 1 }
        let secs = Double(samples.count) / Ears.rate
        samples += [Float](repeating: 0, count: Int(Ears.rate * 3))          // the pause after the last word
        let sessions = ITerm.list()
        let target = val("--to-tty").flatMap { t in sessions.first { $0.tty == t } }
        out(["event": "loaded", "file": path, "secs": secs, "sessions": sessions.count, "target": target?.name ?? "none",
             "target_tty": target?.tty ?? ""])
        let vad = VAD()
        vad.pause = val("--pause").flatMap(Double.init) ?? 1.3
        var done: [([Float], Double)] = []
        var t = 0.0
        vad.onStart = { out(["event": "voice", "at": (t * 100).rounded() / 100]) }
        vad.onNoise = { span in out(["event": "noise", "span": span]) }
        vad.onUtterance = { s, span in done.append((s, span)); out(["event": "utterance", "at": (t * 100).rounded() / 100, "span": span]) }
        let gate = Gate.shared
        let chunk = 1600                                                       // 100 ms
        var fed = 0, gated = 0, sent = 0, heardN = 0, wasClosed = false
        var i = 0
        while i < samples.count {
            let t0 = Date()
            gate.poll()
            let slice = Array(samples[i..<min(i + chunk, samples.count)])
            if gate.closed {
                if !wasClosed { vad.reset(); out(["event": "gate-closed", "at": t, "speaking": gate.speaking, "recording": gate.recording]) }
                wasClosed = true; gated += 1
            } else {
                if wasClosed { out(["event": "gate-open", "at": t]) }
                wasClosed = false; vad.feed(slice); fed += 1
            }
            i += chunk; t += 0.1
            while !done.isEmpty {
                let (s, _) = done.removeFirst()
                let r = Voice.hear(s, lang: lang)
                guard let text = r.text else { out(["event": "hear-error", "error": r.error ?? ""]); continue }
                heardN += 1
                let p = Phrase.classify(text)
                out(["event": "heard", "text": text, "phrase": "\(p)", "noise": Phrase.isNoise(text)])
                if p == .none, !Phrase.isNoise(text), let tg = target {
                    let ok = ITerm.write(text, to: tg.id)
                    if ok { sent += 1 }
                    out(["event": "sent", "ok": ok, "to": tg.name, "tty": tg.tty])
                }
            }
            if realtime { let left = 0.1 - Date().timeIntervalSince(t0); if left > 0 { Thread.sleep(forTimeInterval: left) } }
        }
        out(["event": "done", "chunks_fed": fed, "chunks_gated": gated, "heard": heardN, "sent": sent])
        return 0
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--test-wav") { exit(Bench.run(args)) }
        if args.contains("--list-sessions") {
            for s in ITerm.list().sorted(by: { $0.active > $1.active }) { print("\(s.tty)\t\(s.name)\t\(s.id)") }
            if let d = ITerm.pickDefault(ITerm.list()) { print("default: \(d.name)") }
            exit(0)
        }
        if args.contains("--list-mics") {
            let pick = Devices.pick(savedUID: UserDefaults.standard.string(forKey: "micUID"))
            for d in Devices.inputs() { print("\(d.uid == pick?.uid ? "*" : " ") \(d.name)\t\(d.uid)") }
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = App.shared
        app.run()
    }
}
