// Talk Mode (Mantra): a real conversation with a Claude Code session, hands free. Marko talks and pauses; his words are
// written into the chosen session (iTerm2, `write text`, then Return); Claude answers aloud (langsay through MANTRA_VOICE);
// while the voice talks Talk Mode does not listen; then it listens again. The window says where we are in words big
// enough to read from the camera, three metres away: LISTENING · HEARD: "…" · CLAUDE IS THINKING · SPEAKING.
// Marko, 15.11.2026: "when I say real time talk mode, you are waiting for me to pause, then you say something and we kind
// of do this thing together ... I'm not in front of computer I'm in front of the camera".
//
// Switch: say "real time talk mode" / "talk mode on", and "typing mode" / "talk mode off"; the menu bar
// item; `open -g talkmode://on|off|toggle|repeat|show`. "Say that again" plays the last answer again (/speak/replay).
// Debug path (no microphone, no window): TalkMode --test-wav FILE --to-tty /dev/ttysNNN [--lang en] [--pause 1.3]
import AppKit
import Carbon
import SwiftUI

let VERSION = 8
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
        case .recording, .voiceDown, .noMic, .manual: return red
        case .sending: return amber
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

/// ① the sessions: a folder per device (newest activity first), inside each its sessions (newest first)
struct SessionPicker: View {
    @ObservedObject var talk: Talk

    func folderTitle(_ f: DeviceFolder) -> String {
        guard f.online else { return f.name + "  ·  offline" }
        let n = f.sessions.count
        return f.name + "  ·  " + String(n) + (n == 1 ? " session" : " sessions")
    }

    func rowTitle(_ s: Target) -> String {
        let mark = s.id == talk.target?.id ? "✓ " : ""
        let tail: String = s.deliverable ? (s.detail.isEmpty ? "" : "  ·  " + s.detail) : "  ·  " + s.reason
        return mark + s.name + "  ·  " + Roster.ago(s.active) + tail
    }

    var label: String {
        guard let t = talk.target else { return "CHOOSE THE SESSION" }
        return t.device + "  ›  " + t.name
    }

    var body: some View {
        Menu {
            ForEach(talk.folders) { (f: DeviceFolder) in
                Menu(folderTitle(f)) { folderItems(f) }
            }
            Divider()
            Button(talk.scanning ? "Looking for sessions…" : "Look for sessions again") { talk.refreshSessions() }
        } label: {
            Text(label).foregroundStyle(talk.target == nil ? Ink.amber : Ink.text)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Talk to session")
    }

    @ViewBuilder func folderItems(_ f: DeviceFolder) -> some View {
        if !f.note.isEmpty { Text(f.note) }
        ForEach(f.sessions) { (s: Target) in
            Button(rowTitle(s)) { talk.choose(s) }.disabled(!s.deliverable)
        }
    }
}

/// v6: SEND NOW (the sentence goes now, no waiting for the pause); while a Space take runs it is STOP AND SEND
struct SendNowButton: View {
    @ObservedObject var talk: Talk
    let size: CGFloat
    var body: some View {
        VStack(spacing: 6) {
            Text(talk.manual ? "STOP AND SEND" : "SEND NOW")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(talk.manual ? Ink.red : Ink.text)
                .padding(.horizontal, 18).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(talk.manual ? Ink.red : Ink.dim, lineWidth: 1))
                .fixedSize()
                .word(talk.manual ? "Stop and send" : "Send now", id: "send-now") { talk.sendNow() }
            Text(talk.manual ? "SPACE  ·  stop and send" : "SPACE  ·  record, Space again to send")
                .font(.system(size: max(12, size * 0.45), weight: .semibold, design: .monospaced))
                .foregroundStyle(Ink.dim).fixedSize()
        }
    }
}

/// v8: the ENGINES panel: every engine of Voice to Text for the language, big enough for the camera; a click (or ↑ ↓ and
/// Return while the window is in front) makes it the engine of Voice to Text for that language. Esc closes.
struct EnginePanel: View {
    @ObservedObject var talk: Talk
    let size: CGFloat

    func sortWord(_ key: String, _ word: String) -> some View {
        Text(word).foregroundStyle(talk.engineSort == key ? Ink.green : Ink.grey)
            .word("Sort by \(word.lowercased())", id: "sort-\(key)", value: talk.engineSort == key ? "on" : "off") { talk.engineSort = key }
    }

    func row(_ r: EngineRow, _ i: Int) -> some View {
        let here = i == talk.engineCursor
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(r.selected ? "●" : "○").foregroundStyle(r.selected ? Ink.green : Ink.dim)
                Text(r.short).fontWeight(.heavy).foregroundStyle(r.available ? Ink.text : Ink.grey)
                Text(r.secs.map { String(format: "%.1f s", $0) } ?? "no time yet").foregroundStyle(Ink.dim)
                Text(String(repeating: "★", count: r.stars) + String(repeating: "☆", count: max(0, 5 - r.stars)))
                    .foregroundStyle(Ink.amber)
                if let q = r.quality { Text("\(q) %").foregroundStyle(Ink.dim) }
            }
            .font(.system(size: size, weight: .semibold, design: .rounded))
            Text((r.available ? r.credit : "no key or not installed on this Mac") + "  ·  " + r.route)
                .font(.system(size: max(12, size * 0.55), weight: .medium, design: .monospaced))
                .foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, size * 1.2)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(r.selected ? Ink.green.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(here ? Ink.text.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { talk.engineCursor = i; if r.available { talk.pickEngine(r.id) } }
        .axButton("\(r.short), \(r.selected ? "in use" : "not in use")", id: "engine-\(r.id)", value: r.credit) {
            if r.available { talk.pickEngine(r.id) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("ENGINES · " + (talk.lang == "hr" ? "CROATIAN" : "ENGLISH"))
                    .font(.system(size: size * 1.2, weight: .black, design: .rounded)).fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    sortWord("best", "BEST"); Text("|").foregroundStyle(Ink.dim)
                    sortWord("stars", "STARS"); Text("|").foregroundStyle(Ink.dim)
                    sortWord("time", "TIME")
                }
                .font(.system(size: max(13, size * 0.6), weight: .bold, design: .monospaced)).fixedSize()
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 24, height: 24).word("Close the engines", id: "engines-close") { talk.closeEngines() }
            }
            if !talk.engineNote.isEmpty {
                Text(talk.engineNote).font(.system(size: max(13, size * 0.6))).foregroundStyle(Ink.amber)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(talk.engines.enumerated()), id: \.element.id) { (i: Int, r: EngineRow) in
                            row(r, i).id(r.id)
                        }
                    }
                }
                .onChange(of: talk.engineCursor) { c in
                    if talk.engines.indices.contains(c) { withAnimation { proxy.scrollTo(talk.engines[c].id) } }
                }
            }
            Text("↑ ↓ choose  ·  RETURN use it  ·  ESC close  ·  credit from this Mac's own records")
                .font(.system(size: max(11, size * 0.5), weight: .medium, design: .monospaced)).foregroundStyle(Ink.dim)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Ink.ground)
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
                    Text(talk.auto ? "AUTO" : "MANUAL")
                        .font(.system(size: max(20, big * 0.34), weight: .black, design: .rounded))
                        .foregroundStyle(talk.auto ? Ink.green : Ink.amber)
                        .padding(.horizontal, 14).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(talk.auto ? Ink.green : Ink.amber, lineWidth: 2))
                        .fixedSize()
                        .word(talk.auto ? "Mode auto" : "Mode manual", id: "mode-big") { talk.auto.toggle() }
                    Text(!talk.auto && talk.state == .listening ? "PRESS SPACE" : talk.state.word)
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
                        if !talk.heardVia.isEmpty {
                            Text("WRITTEN DOWN BY  " + talk.heardVia)
                                .font(.system(size: max(13, big * 0.12), weight: .semibold, design: .monospaced))
                                .foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("heard-via")
                        }
                    }
                    SendNowButton(talk: talk, size: max(16, big * 0.2))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .frame(width: g.size.width, height: g.size.height)
                .opacity(talk.enginesOpen ? 0 : 1)
                .overlay { if talk.enginesOpen { EnginePanel(talk: talk, size: max(17, big * 0.17)).frame(width: g.size.width, height: g.size.height) } }
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
                        SessionPicker(talk: talk)
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
                Cell(label: "EARS · TIME · QUALITY") {
                    HStack(spacing: 10) {
                        Text(talk.earsText(talk.lang)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ears")
                        Text(talk.enginesOpen ? "CLOSE" : "CHANGE").foregroundStyle(Ink.amber).fixedSize()
                            .word(talk.enginesOpen ? "Close the engines" : "Change the engine", id: "engines") {
                                talk.enginesOpen ? talk.closeEngines() : talk.openEngines() }
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
                Cell(label: "SENDS") {
                    HStack(spacing: 6) {
                        Text("AUTO").foregroundStyle(talk.auto ? Ink.green : Ink.grey)
                            .word("Auto: sends after the pause", id: "mode-auto", value: talk.auto ? "on" : "off") { talk.auto = true }
                        Text("|").foregroundStyle(Ink.dim)
                        Text("MANUAL").foregroundStyle(talk.auto ? Ink.grey : Ink.amber)
                            .word("Manual: Space records, Space again sends", id: "mode-manual", value: talk.auto ? "off" : "on") { talk.auto = false }
                    }
                }
                Cell(label: "LAST ANSWER") {
                    Text("SAY IT AGAIN").foregroundStyle(Ink.text).word("Say the last answer again", id: "repeat") { talk.repeatLast() }
                }
            }
            if !talk.note.isEmpty {
                Text(talk.note).font(.system(size: 13)).foregroundStyle(Ink.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// ---------------------------------------------------------------- the app
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static let shared = App()
    /// --preview <state> --shot <file.png> [--size WxH]: the window drawn off screen into a picture, then the app quits
    static let shot: String? = CommandLine.arguments.firstIndex(of: "--shot").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    var window: NSWindow?
    private var status: NSStatusItem?
    private var activity: NSObjectProtocol?
    private var observer: Any?
    private var spaceMonitor: Any?

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        mainMenu()
        if App.shot == nil { makeStatusItem() }
        makeWindow()
        if let i = CommandLine.arguments.firstIndex(of: "--preview") {      // the window alone, for a screenshot: no ears, no sessions
            let a = CommandLine.arguments
            Talk.shared.preview(i + 1 < a.count ? a[i + 1] : "listening")
            if let j = a.firstIndex(of: "--size"), j + 1 < a.count {
                let p = a[j + 1].split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { window?.setContentSize(NSSize(width: p[0], height: p[1])) }
            }
            if let path = App.shot {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let v = self.window?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("shot \(path)"); exit(0)
                }
            }
            return
        }
        // v7: no global shortcut (Marko, 15.11.2026: "this shortcut is not necessary ... we have mode Auto Advanced and Manual and we have spacebar")
        // listening goes on with the window behind others (no App Nap)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "listening for Marko")
        Talk.shared.start()
        // v6: Space records and sends, only while this window is in front (a local monitor never sees other apps' keys)
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if Talk.shared.enginesOpen, NSApp.isActive, self?.window?.isKeyWindow == true,
               e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch e.keyCode {
                case 126: Talk.shared.moveEngineCursor(-1); return nil      // ↑
                case 125: Talk.shared.moveEngineCursor(1); return nil       // ↓
                case 36, 76: Talk.shared.pickAtCursor(); return nil          // Return
                case 53: Talk.shared.closeEngines(); return nil              // Esc
                default: break
                }
            }
            guard e.keyCode == 49, !e.isARepeat,
                  e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  NSApp.isActive, let w = self?.window, w.isKeyWindow, !(w.firstResponder is NSTextView) else { return e }
            Talk.shared.spacePressed()
            return nil
        }
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
        window = w
        enforceOneTitle(w)
        if App.shot != nil {                       // --shot: drawn off every screen, nothing comes to the front
            w.setFrameOrigin(NSPoint(x: -20000, y: -20000)); w.orderFront(nil)
        } else {
            w.center()
            w.setFrameAutosaveName("TalkModeMain")
            w.makeKeyAndOrderFront(nil)
        }
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
        let toggle = NSMenuItem(title: t.on ? "Typing Mode (talk mode off)" : "Talk Mode On", action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self; m.addItem(toggle)
        let rec = NSMenuItem(title: t.manual ? "Stop and Send" : "Record (Space in the window)", action: #selector(menuSpace), keyEquivalent: "")
        rec.target = self; m.addItem(rec)
        let mode = NSMenuItem(title: t.auto ? "Mode: Auto (switch to Manual)" : "Mode: Manual (switch to Auto)", action: #selector(menuMode), keyEquivalent: "")
        mode.target = self; m.addItem(mode)
        let eng = NSMenuItem(title: "Engines… (Voice to Text)", action: #selector(menuEngines), keyEquivalent: ""); eng.target = self; m.addItem(eng)
        let now = NSMenuItem(title: "Send Now", action: #selector(menuSendNow), keyEquivalent: ""); now.target = self; m.addItem(now)
        let again = NSMenuItem(title: "Say the Last Answer Again", action: #selector(menuRepeat), keyEquivalent: ""); again.target = self; m.addItem(again)
        m.addItem(.separator())
        let ses = NSMenuItem(title: "Talk To", action: nil, keyEquivalent: ""), sm = NSMenu()
        for f in t.folders {
            let fi = NSMenuItem(title: f.name + "  ·  " + (f.online ? "\(f.sessions.count)" : "offline"), action: nil, keyEquivalent: ""), fm = NSMenu()
            if !f.note.isEmpty { fm.addItem(withTitle: f.note, action: nil, keyEquivalent: "") }
            for s in f.sessions {
                let i = NSMenuItem(title: s.name + "  ·  " + Roster.ago(s.active) + (s.deliverable ? "" : "  ·  " + s.reason),
                                   action: s.deliverable ? #selector(menuSession(_:)) : nil, keyEquivalent: "")
                i.target = self; i.representedObject = s.id; i.state = s.id == t.target?.id ? .on : .off; fm.addItem(i)
            }
            fi.submenu = fm; sm.addItem(fi)
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
            let i = NSMenuItem(title: name + " · " + t.earsText(code), action: #selector(menuLang(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = code; i.state = t.lang == code ? .on : .off; lm.addItem(i)
        }
        lang.submenu = lm; m.addItem(lang)
        m.addItem(.separator())
        let show = NSMenuItem(title: "Show Window", action: #selector(menuShow), keyEquivalent: ""); show.target = self; m.addItem(show)
        m.addItem(withTitle: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        t.refreshSessions()
    }

    @objc func menuToggle() { Talk.shared.toggle() }
    @objc func menuSpace() { Talk.shared.spacePressed() }
    @objc func menuSendNow() { Talk.shared.sendNow() }
    @objc func menuMode() { Talk.shared.auto.toggle() }
    @objc func menuEngines() { showWindow(); Talk.shared.openEngines() }
    @objc func menuRepeat() { Talk.shared.repeatLast() }
    @objc func menuShow() { showWindow() }
    @objc func menuSession(_ i: NSMenuItem) {
        if let id = i.representedObject as? String, let s = Talk.shared.folders.flatMap(\.sessions).first(where: { $0.id == id }) { Talk.shared.choose(s) }
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
        let t = NSMenuItem(title: "Talk Mode On / Typing Mode", action: #selector(menuToggle), keyEquivalent: "")
        t.target = self; talkMenu.addItem(t)
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

    /// --to <id from --list-sessions> (any device), or --to-tty /dev/ttysNNN (any iTerm2 tab, e.g. a throwaway `cat`)
    static func target(_ a: [String]) -> Target? {
        func val(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let tty = val("--to-tty"), let tab = ITerm.list().first(where: { $0.tty == tty }) {
            return Target(kind: .mac, device: "MacBook Pro", key: tab.id, name: tab.name, detail: tty, active: tab.active, deliverable: true, reason: "")
        }
        if let id = val("--to") ?? val("--deliver") { return Roster.scan().flatMap(\.sessions).first { $0.id == id } }
        return nil
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
        let target = Bench.target(a)
        out(["event": "loaded", "file": path, "secs": secs, "target": target?.name ?? "none", "target_id": target?.id ?? ""])
        let vad = VAD()
        vad.pause = val("--pause").flatMap(Double.init) ?? 1.3
        var done: [([Float], Double)] = []
        var t = 0.0
        vad.onStart = { out(["event": "voice", "at": String(format: "%.1f", t)]) }
        vad.onNoise = { span in out(["event": "noise", "span": span]) }
        vad.onUtterance = { s, span in done.append((s, span)); out(["event": "utterance", "at": String(format: "%.1f", t), "span": span]) }
        let gate = Gate.shared
        let chunk = 1600                                                       // 100 ms
        var fed = 0, gated = 0, sent = 0, heardN = 0, wasClosed = false
        var i = 0
        while i < samples.count {
            let t0 = Date()
            gate.poll()
            let slice = Array(samples[i..<min(i + chunk, samples.count)])
            if gate.closed {
                if !wasClosed { vad.reset(); out(["event": "gate-closed", "at": String(format: "%.1f", t), "speaking": gate.speaking, "recording": gate.recording]) }
                wasClosed = true; gated += 1
            } else {
                if wasClosed { out(["event": "gate-open", "at": String(format: "%.1f", t)]) }
                wasClosed = false; vad.feed(slice); fed += 1
            }
            i += chunk; t += 0.1
            while !done.isEmpty {
                let (s, _) = done.removeFirst()
                var r: (String?, String?, String)
                if a.contains("--mantra-voice") { let v = Voice.hear(s, lang: lang); r = (v.text, v.error, "MANTRA_VOICE") }
                else { let h = Hearing.hear(s, lang: lang); r = (h.text, h.error, h.via) }
                guard let text = r.0 else { out(["event": "hear-error", "error": r.1 ?? "", "via": r.2]); continue }
                heardN += 1
                let p = Phrase.classify(text)
                out(["event": "heard", "text": text, "via": r.2, "phrase": "\(p)", "noise": Phrase.isNoise(text)])
                if p == .none, !Phrase.isNoise(text), let tg = target {
                    let (ok, why) = Deliver.send(text, to: tg)
                    if ok { sent += 1 }
                    out(["event": "sent", "ok": ok, "to": tg.name, "device": tg.device, "why": why])
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
            let all = Roster.scan()
            for f in all {
                print("\(f.name)  [\(f.online ? "online" : "offline")]\(f.note.isEmpty ? "" : "  " + f.note)")
                for s in f.sessions {
                    print("    \(s.deliverable ? " " : "x") \(s.name)  ·  \(Roster.ago(s.active))  ·  \(s.detail)  ·  id \(s.id)\(s.deliverable ? "" : "  ·  " + s.reason)")
                }
            }
            if let d = Roster.pickDefault(all) { print("default: \(d.device) › \(d.name)") }
            exit(0)
        }
        if let i = args.firstIndex(of: "--deliver"), i + 1 < args.count {     // --deliver <target id|--to-tty> "text"
            guard let t = Bench.target(args) else { print("no such target"); exit(1) }
            let (ok, why) = Deliver.send(args.last ?? "", to: t)
            print(ok ? "delivered to \(t.device) › \(t.name)" : "NOT delivered: \(why)"); exit(ok ? 0 : 1)
        }
        if args.contains("--list-mics") {
            let pick = Devices.pick(savedUID: UserDefaults.standard.string(forKey: "micUID"))
            for d in Devices.inputs() { print("\(d.uid == pick?.uid ? "*" : " ") \(d.name)\t\(d.uid)") }
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(args.contains("--shot") ? .accessory : .regular)
        app.delegate = App.shared
        app.run()
    }
}
