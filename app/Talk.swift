// Talk.swift: the conversation. Marko talks, pauses; his words go to the chosen Claude Code session; Claude answers aloud
// through the voice (every reply ends with langsay); while the voice talks Talk Mode is deaf; then it listens again.
// In typing mode the ears stay open only for the switch phrase ("real time talk mode"), short utterances only.
import AppKit
import Foundation

enum TalkState: Equatable {
    case typing, listening, hearing, writing, thinking, speaking, recording, voiceDown, noMic(String), noTarget, manual, sending

    /// v16 (Marko, 16.11.2026: "the big ones should be very clear with only one word ... LISTENING, RECORDING, thinking, reply").
    /// The standard of MANTRA_MANIFEST modules/talk-states.md: ONE word each. LISTENING (green) = the microphone is open and waits
    /// for his voice; RECORDING (red) = his voice is being recorded, from the first moment of speech; THINKING (violet) = sent or
    /// being turned into text, waiting for Claude; REPLYING (orange) = the answer is being spoken; OFF (grey) = Talk Mode is off.
    /// Faults are one or two words too (NO MIC, NO VOICE, NO SESSION); another recorder holding the mic is VOX BUSY.
    var word: String {
        switch self {
        case .typing: return "OFF"
        case .listening: return "LISTENING"
        case .hearing: return "RECORDING"
        case .writing: return "THINKING"
        case .thinking: return "THINKING"
        case .speaking: return "REPLYING"
        case .recording: return "VOX BUSY"
        case .voiceDown: return "NO VOICE"
        case .noMic: return "NO MIC"
        case .noTarget: return "NO SESSION"
        case .manual: return "RECORDING"
        case .sending: return "THINKING"
        }
    }

    /// the small line under the big word (secondary information, never big)
    var hint: String {
        switch self {
        case .typing: return "switch TALK MODE on to talk"
        case .listening: return "microphone is open"
        case .hearing, .manual: return "your voice is being recorded"
        case .writing, .sending: return "turning your voice into text"
        case .thinking: return "Claude is working on the answer"
        case .speaking: return "Claude is speaking"
        case .recording: return "Voice to Text is recording; I wait"
        case .voiceDown: return "the voice engine does not answer"
        case .noMic: return "no microphone to listen with"
        case .noTarget: return "choose a session in step 1"
        }
    }

    /// the same state as one plain sentence (state.json `plain`, Queen's "talk mode status")
    var plain: String {
        switch self {
        case .typing: return "Talk Mode is off: I only listen for the words that switch it on, nothing is sent."
        case .listening: return "I am listening; say something, I send it after your pause."
        case .hearing: return "I hear you speaking right now."
        case .writing: return "You finished a sentence; I am turning it into text."
        case .thinking: return "Your words are in the Claude Code session; Claude is working on the answer."
        case .speaking: return "Claude is speaking the answer; I do not listen until it is finished."
        case .recording: return "Voice to Text (Vox) is recording; I do not listen until it stops, then I listen again."
        case .voiceDown: return "The voice engine (MANTRA_VOICE) does not answer; I am trying to start it."
        case .noMic: return "I have no microphone to listen with."
        case .noTarget: return "No Claude Code session is chosen; pick one in step 1."
        case .manual: return "You are recording with Talk Mode; press Space or STOP AND SEND to send it."
        case .sending: return "I am sending your recording to the session."
        }
    }
}

final class Talk: ObservableObject {
    static let shared = Talk()

    @Published private(set) var on: Bool
    @Published private(set) var state: TalkState = .typing
    @Published private(set) var heard = "" { didSet { heardChanged() } }
    /// v13 (Marko, 15.11.2026: "annoying text ... heard mother what's happening again"): HEARD lives only while the words are
    /// being sent and 6 s after; then it clears (the view fades it). `heardFresh` is false for the fade.
    @Published private(set) var heardFresh = true
    private var heardTimer: Timer?
    private func heardChanged() {
        heardTimer?.invalidate()
        guard !heard.isEmpty, App.shot == nil else { heardFresh = true; return }
        heardFresh = true
        heardTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            guard let me = self else { return }
            me.heardFresh = false                                           // fades out over 0.6 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { if !me.heardFresh { me.clearHeard() } }
        }
    }
    private func clearHeard() { heard = ""; saveState() }
    @Published private(set) var note = ""
    @Published private(set) var levelDB: Float = -90
    @Published private(set) var folders: [DeviceFolder] = []
    @Published private(set) var target: Target?
    @Published private(set) var heardVia = ""
    @Published private(set) var scanning = false
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var device: InputDevice?
    /// v11: the language is Voice to Text's (its pill: EN, HR or AUTO), read from its /status; no selector here any more
    @Published private(set) var lang: String = "en"
    /// v16 (Marko, 16.11.2026: "I press space, I see the message and then I add more and then when I'm ready I press enter ... the switch
    /// will be called Auto Send without Enter"): in SPACE BAR MODE each Space take is APPENDED to this draft; Enter sends the whole draft,
    /// Esc clears it. The switch AUTO SEND WITHOUT ENTER (default OFF = the draft) restores the old way: each take is sent at once.
    @Published private(set) var draft = ""
    @Published var autoSendNoEnter: Bool = UserDefaults.standard.bool(forKey: "autoSendNoEnter") {
        didSet { UserDefaults.standard.set(autoSendNoEnter, forKey: "autoSendNoEnter"); saveState() }
    }
    /// a 2 s flash of a switch that an F-key just turned (window and menu bar item)
    @Published private(set) var flash = ""
    func flashed(_ t: String) {
        flash = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.flash == t { self.flash = "" } }
    }
    func sendDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !t.isEmpty else { return }
        remember(t); send(t)
    }
    func clearDraft() { if !draft.isEmpty { draft = ""; flashed("DRAFT CLEARED") } }
    /// the F-keys: F5 TALK MODE, F6 AUTO, F7 SPACE BAR MODE, F8 AUTO SEND WITHOUT ENTER (the order of the cheat sheet in the window)
    static let switches = ["TALK MODE", "AUTO", "SPACE BAR MODE", "AUTO SEND WITHOUT ENTER"]
    static let fKeyCodes: [Int64] = [96, 97, 98, 100]
    func toggleSwitch(_ i: Int) {
        guard Talk.switches.indices.contains(i) else { return }
        var now = false
        switch i {
        case 0: setOn(!on); now = on
        case 1: auto.toggle(); now = auto
        case 2: if SpaceMode.shared.on { SpaceMode.shared.disable("switch") } else { SpaceMode.shared.enable(); now = true }
        default: autoSendNoEnter.toggle(); now = autoSendNoEnter
        }
        flashed("F\(i + 1) " + Talk.switches[i] + (now ? " ON" : " OFF"))
    }
    @Published var pause: Double { didSet { UserDefaults.standard.set(pause, forKey: "pause"); work.async { self.vad.pause = self.pause } } }
    @Published var minLength: Double { didSet { UserDefaults.standard.set(minLength, forKey: "minLength"); work.async { self.vad.minLength = self.minLength } } }

    /// v5 (Marko, 15.11.2026: "how good is each engine and how fast is each engine in the engine name everywhere"): the engine of each
    /// language with its median time and stars, read from Voice to Text's /engines ("Deepgram · 1.0 s · ★★★★☆")
    @Published private(set) var earsLabel: [String: String] = [:]
    func refreshEars() {
        DispatchQueue.global().async {
            let l = Hearing.engineLabels()
            let lg = Hearing.currentLang()
            DispatchQueue.main.async {
                if !l.isEmpty { self.earsLabel = l }
                if let lg, lg != self.lang { self.lang = lg; self.saveState() }
            }
        }
    }
    func earsText(_ code: String) -> String { earsLabel[code] ?? "Voice to Text not answering" }

    /// v6: Space / SEND NOW. `manual` (main) is the push-to-talk take; manualOn/manualBuf/forcedFlag live on the work queue
    @Published private(set) var manual = false
    /// --preview space: the window as it looks with SPACE MODE on (nothing is locked)
    @Published private(set) var spacePreview = false
    /// v7 (Marko, 15.11.2026: "a switch which is like auto advanced mode or manual mode"): AUTO sends after the pause;
    /// MANUAL sends nothing by itself: Space (or the button) records, the second Space / SEND NOW sends
    @Published var auto: Bool = UserDefaults.standard.object(forKey: "autoMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "autoMode"); saveState(); App.shared.refreshStatusItem() }
    }
    private var manualOn = false
    private var manualBuf: [Float] = []
    private var forcedFlag = false

    private let ears = Ears()
    private let vad = VAD()
    private let work = DispatchQueue(label: "talk.vad")
    private let hearQ = DispatchQueue(label: "talk.hear")
    private var thinkingSince: Date?
    private var tick: Timer?
    private var lastLevelPush = Date.distantPast
    private var wasClosed = false

    private init() {
        let d = UserDefaults.standard
        on = d.bool(forKey: "talkOn")
        pause = d.object(forKey: "pause") as? Double ?? 1.3
        minLength = d.object(forKey: "minLength") as? Double ?? 0.6
        refreshEars()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.refreshEars() }
        RunLoop.main.add(t, forMode: .common)
    }

    // ------------------------------------------------------------ start
    func start() {
        vad.pause = pause; vad.minLength = minLength
        vad.onStart = { [weak self] in DispatchQueue.main.async { self?.voiceStarted() } }
        vad.onNoise = { [weak self] _ in DispatchQueue.main.async { self?.voiceEnded() } }
        vad.onUtterance = { [weak self] s, span in self?.utterance(s, span) }
        ears.onSamples = { [weak self] s in self?.work.async { self?.samples(s) } }
        Gate.shared.startPolling()
        refreshDevices()
        startEars()
        refreshSessions()
        tick = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.update() }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshSessions() }
        saveState()
    }

    private func startEars() {
        do { try ears.start(device: device); note = "" }
        catch { state = .noMic(error.localizedDescription); note = "Microphone: \(error.localizedDescription)" }
    }

    // ------------------------------------------------------------ audio (work queue)
    private func samples(_ s: [Float]) {
        if manualOn {                                  // Space pressed: everything goes into the take, no detector
            if Gate.shared.closed { return }
            manualBuf.append(contentsOf: s)
            var sum: Float = 0
            for x in s { sum += x * x }
            let l = 20 * log10(max(sqrt(sum / Float(max(1, s.count))), 1e-7))
            let now = Date()
            if now.timeIntervalSince(lastLevelPush) > 0.1 { lastLevelPush = now; DispatchQueue.main.async { self.levelDB = l } }
            return
        }
        let closed = Gate.shared.closed
        if closed {
            if !wasClosed { vad.reset() }              // a half utterance with the voice in it is thrown away
            wasClosed = true
            return
        }
        wasClosed = false
        vad.feed(s)
        let now = Date()
        if now.timeIntervalSince(lastLevelPush) > 0.1 {
            lastLevelPush = now
            let l = vad.levelDB
            DispatchQueue.main.async { self.levelDB = l }
        }
    }

    private func utterance(_ s: [Float], _ span: Double) {
        let forced = forcedFlag
        let talking = DispatchQueue.main.sync { self.on && (self.auto || forced) }
        if !talking && !forced && span > 4 { DispatchQueue.main.async { self.voiceEnded() }; return }   // typing mode: only short phrases
        DispatchQueue.main.async { if forced { self.state = .sending } else if self.on { self.state = .writing } }
        let language = Hearing.currentLang() ?? DispatchQueue.main.sync { self.lang }   // v11: Voice to Text's language, now
        if talking || forced { keepTake(s) }
        hearQ.async {
            let r = Hearing.hear(s, lang: talking || forced ? language : "en")
            DispatchQueue.main.async {
                if talking { self.heardVia = r.via }
                self.handle(r.text, error: r.error, forced: forced); self.refreshEars()
                if self.state == .sending { self.state = self.on ? .listening : .typing }
            }
        }
    }

    // ------------------------------------------------------------ main thread
    private func voiceStarted() { if on, auto, state == .listening { state = .hearing } }
    private func voiceEnded() { if on, state == .hearing { state = .listening } }

    private func handle(_ text: String?, error: String?, forced: Bool = false) {
        guard let text else {
            if on { note = error ?? ""; state = .listening }
            if error != nil { Voice.startIfDown() }
            return
        }
        NSLog("[Talk] heard (%@): %@", on ? "talk" : "typing", text)
        // v11: in Space Mode, "space mode off" / "go out of this mode" / "I want my keyboard back" ends it (never sent)
        if SpaceMode.shared.on, SpaceExit.matches(text) {
            heard = text; SpaceMode.shared.disable("voice"); state = on ? .listening : .typing; return
        }
        switch Phrase.classify(text) {
        case .on:
            if !on { setOn(true) } else { state = .listening }
            return
        case .off:
            if on { setOn(false) }
            return
        case .repeatLast where on && (auto || forced):
            heard = text; note = "saying the last answer again"
            Voice.replay()
            state = .listening
            return
        default: break
        }
        guard (on && auto) || forced else { return }
        if Phrase.isNoise(text) { ignore(text, "known noise phrase"); return }
        if !forced, let why = duplicate(text) { ignore(text, why); return }
        remember(text)
        if forced, SpaceMode.shared.on, !autoSendNoEnter {       // v16: the take joins the draft; Enter sends it
            draft = draft.isEmpty ? text : draft + " " + text
            heard = ""; note = ""
            return
        }
        send(text)
    }

    // v13 (Marko 15.11.2026, three Whisper hallucinations sent while he was away): dropped ones never reach the session; they show
    // for 4 s as "ignored (noise)" and are logged in ignored.log beside state.json
    private var recent: [(Set<String>, Date)] = []
    private func words(_ t: String) -> Set<String> { Set(Phrase.norm(t).split(separator: " ").map(String.init)) }
    private func duplicate(_ text: String) -> String? {
        let w = words(text)
        recent.removeAll { Date().timeIntervalSince($0.1) > 120 }
        for (p, _) in recent where !w.isEmpty {
            let j = Double(w.intersection(p).count) / Double(max(1, w.union(p).count))
            if j >= 0.8 { return "same as a sentence of the last 2 minutes" }
        }
        return nil
    }
    private func remember(_ text: String) { recent.append((words(text), Date())) }
    private func ignore(_ text: String, _ why: String) {
        NSLog("[Talk] ignored (noise): %@ (%@)", text, why)
        state = on ? .listening : .typing
        if on { note = "ignored (noise): “\(text.prefix(60))”" }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(why)\t\(text)\n"
        let url = Talk.stateFile.deletingLastPathComponent().appendingPathComponent("ignored.log")
        if let d = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: url) }
        }
        let mine = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.note == mine { self.note = "" } }
    }

    func send(_ text: String) {
        guard let t = target else { state = .noTarget; note = "Choose the session in ①"; return }
        heard = text
        state = .thinking
        thinkingSince = Date()
        DispatchQueue.global().async {
            Voice.seen()                                   // REPLAY starts from the answer to these words
            let (ok, why) = Deliver.send(text, to: t)
            DispatchQueue.main.async {
                if !ok {
                    self.note = why + ": choose the session again"
                    self.state = .noTarget
                    self.refreshSessions()
                } else { self.note = "" }
                self.saveState()
            }
        }
    }

    /// the state follows the voice and the gate, 7 times a second
    private func update() {
        if manual { if state != .manual { state = .manual; saveState() }; return }
        if state == .sending { return }
        levelDB = Gate.shared.closed ? -90 : levelDB
        if !Gate.shared.reachable { Voice.startIfDown() }
        guard on else { if state != .typing { state = .typing; saveState() }; return }
        let g = Gate.shared
        var next = state
        if case .noMic = state { return }
        if !g.reachable { next = .voiceDown }
        else if g.recording { next = .recording }
        else if g.speaking { next = .speaking; thinkingSince = nil }
        else if state == .speaking || state == .recording || state == .voiceDown { next = g.closed ? state : .listening }
        else if state == .thinking, let s = thinkingSince, Date().timeIntervalSince(s) > 180 { next = .listening; thinkingSince = nil }
        else if state == .noTarget, target != nil { next = .listening }
        if next != state { state = next; saveState() }
    }

    func setOn(_ v: Bool, speak: Bool = true) {
        on = v
        UserDefaults.standard.set(v, forKey: "talkOn")
        state = v ? (target == nil ? .noTarget : .listening) : .typing
        if v { heard = "" }
        if speak { Voice.say(v ? "Talk mode on. I am listening." : "Typing mode.") }
        work.async { self.vad.reset() }
        App.shared.refreshStatusItem()
        saveState()
    }

    func toggle() { setOn(!on) }

    // ------------------------------------------------------------ v8: the ENGINES panel (remote control of Voice to Text)
    @Published private(set) var enginesOpen = false
    @Published private(set) var engines: [EngineRow] = []
    @Published var engineSort: String = UserDefaults.standard.string(forKey: "engineSort") ?? "best" {
        didSet { UserDefaults.standard.set(engineSort, forKey: "engineSort"); engines = Hearing.sorted(engines, by: engineSort) }
    }
    @Published var engineCursor = 0
    @Published private(set) var engineNote = ""

    /// the panel's language: Voice to Text's; AUTO uses its Croatian engine, as Voice to Text itself does
    var panelLang: String { lang == "auto" ? "hr" : lang }
    func openEngines() { enginesOpen = true; engineNote = "reading Voice to Text…"; loadEngines(moveCursor: true) }
    func closeEngines() { enginesOpen = false }

    func loadEngines(moveCursor: Bool = false) {
        let l = panelLang, by = engineSort
        DispatchQueue.global().async {
            let rows = Hearing.engines(lang: l).map { Hearing.sorted($0, by: by) }
            DispatchQueue.main.async {
                guard let rows else { self.engineNote = "Voice to Text (Mantra) does not answer on 127.0.0.1:8865"; self.engines = []; return }
                self.engines = rows
                self.engineNote = ""
                if moveCursor { self.engineCursor = rows.firstIndex(where: \.selected) ?? 0 }
            }
        }
    }

    func pickEngine(_ id: String) {
        let l = panelLang
        engineNote = "switching…"
        DispatchQueue.global().async {
            let (ok, what) = Hearing.select(id, lang: l)
            DispatchQueue.main.async {
                self.engineNote = ok ? "\(l.uppercased()) now: \(what)" : what
                self.loadEngines()
                self.refreshEars()
            }
        }
    }

    func moveEngineCursor(_ d: Int) {
        guard !engines.isEmpty else { return }
        engineCursor = max(0, min(engines.count - 1, engineCursor + d))
    }

    func pickAtCursor() {
        guard engines.indices.contains(engineCursor) else { return }
        let r = engines[engineCursor]
        if r.available { pickEngine(r.id) } else { engineNote = "\(r.short) has no key on this Mac" }
    }

    // ------------------------------------------------------------ v6: Space and SEND NOW (Marko, 15.11.2026: "build button to
    // send transcription now without waiting shortcut key if app is in focus is space for both star recording and transcribe")
    /// Space: the first press starts a take (the voice stops if it talks: he has the floor), the second sends it
    func spacePressed() { manual ? sendNow() : startManual() }

    func startManual() {
        manual = true; state = .manual; note = ""
        if Gate.shared.speaking { Voice.stop() }
        work.async { self.vad.reset(); self.manualBuf = []; self.manualOn = true }
        saveState()
    }

    /// SEND NOW: the take (Space) or the sentence being heard (the detector) is written down and sent at once
    /// v15: Esc while a Space take is recording: stop, throw the take away, nothing is transcribed or sent
    func cancelTake() {
        guard manual else { return }
        manual = false
        work.async { self.manualOn = false; self.manualBuf = []; self.vad.reset() }
        note = "cancelled"
        state = on ? .listening : .typing
        saveState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.note == "cancelled" { self.note = "" } }
    }

    func sendNow() {
        if manual {
            manual = false; state = .sending; saveState()
            work.async {
                self.manualOn = false
                let s = self.manualBuf; self.manualBuf = []
                self.vad.reset()
                if Double(s.count) / Ears.rate < 0.3 {
                    DispatchQueue.main.async { self.note = "nothing was recorded"; self.state = self.on ? .listening : .typing }
                    return
                }
                self.forcedFlag = true; self.utterance(s, Double(s.count) / Ears.rate); self.forcedFlag = false
            }
        } else {
            work.async { self.forcedFlag = true; self.vad.forceEnd(); self.forcedFlag = false }
        }
    }

    /// --preview <state>: the window filled with examples, nothing listens, nothing is sent (screenshots only)
    func preview(_ what: String) {
        on = what != "typing"
        let all: [String: TalkState] = ["listening": .listening, "hearing": .hearing, "writing": .writing, "thinking": .thinking,
                                        "speaking": .speaking, "typing": .typing, "recording": .recording, "down": .voiceDown,
                                        "manual": .manual, "sending": .sending]
        state = all[what] ?? .listening
        manual = what == "manual"
        spacePreview = what == "space"
        draft = what == "space" ? "Please check the render of the second version" : ""
        if what == "engines" {
            enginesOpen = true
            engines = Hearing.sorted([
                EngineRow(id: "deepgram", label: "", short: "Deepgram", stars: 4, quality: 88, secs: 0.9, available: true, selected: true,
                          credit: "trial credit · 638 h left of 639 h · 3 keys", route: "Frankfurt"),
                EngineRow(id: "parakeet", label: "", short: "Parakeet", stars: 3, quality: 69, secs: 0.4, available: true, selected: false,
                          credit: "this Mac · free", route: "this Mac"),
                EngineRow(id: "groq_turbo", label: "", short: "Groq turbo", stars: 4, quality: 86, secs: nil, available: true, selected: false,
                          credit: "free 8.0 h a day · 7.9 h left today · 8 keys", route: "Frankfurt"),
                EngineRow(id: "soniox", label: "", short: "Soniox", stars: 0, quality: nil, secs: nil, available: false, selected: false,
                          credit: "paid · $0.10 an hour", route: "Frankfurt")], by: engineSort)
            engineCursor = 0
        }
        heard = ["thinking", "speaking", "writing"].contains(what)
            ? "Please check the render of the second version and tell me when the upload to Drive is finished." : ""
        let mac = [Target(kind: .mac, device: "MacBook Pro", key: "p1", name: "mac23_15-11_(real talk mode)", detail: "claude-code · busy",
                          active: Date(), deliverable: true, reason: "")]
        folders = [DeviceFolder(name: "MacBook Pro", online: true, note: "", sessions: mac)]
        target = mac.first
        heardVia = "Deepgram EN · Frankfurt · 1.1 s"
        devices = [InputDevice(id: 0, uid: "preview", name: "External Microphone")]
        device = devices.first
        levelDB = -30
    }
    func repeatLast() { Voice.replay() }

    // ------------------------------------------------------------ sessions and microphones
    func refreshSessions() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global().async {
            let all = Roster.scan()
            DispatchQueue.main.async {
                self.scanning = false
                self.folders = all
                let flat = all.flatMap(\.sessions)
                let d = UserDefaults.standard
                if let cur = self.target, let same = flat.first(where: { $0.id == cur.id }) { self.target = same }
                else if let id = d.string(forKey: "targetID"), let s = flat.first(where: { $0.id == id }) { self.target = s }
                else if let n = d.string(forKey: "targetName"), let s = flat.first(where: { $0.name == n && $0.deliverable }) { self.target = s }
                else if self.target == nil || self.target?.kind == .mac { self.target = Roster.pickDefault(all) }
                if self.on, self.state == .noTarget, self.target != nil { self.state = .listening }
                self.saveState()
            }
        }
    }

    func choose(_ s: Target) {
        guard s.deliverable else { note = "\(s.device): \(s.reason)"; return }
        target = s
        UserDefaults.standard.set(s.id, forKey: "targetID")
        UserDefaults.standard.set(s.name, forKey: "targetName")
        if on, state == .noTarget { state = .listening }
        note = ""
        saveState()
    }

    func refreshDevices() {
        devices = Devices.inputs()
        device = Devices.pick(savedUID: UserDefaults.standard.string(forKey: "micUID"))
    }

    func choose(_ d: InputDevice) {
        device = d
        UserDefaults.standard.set(d.uid, forKey: "micUID")
        work.async { self.vad.reset() }
        startEars()
        if case .noMic = state { state = on ? .listening : .typing }
        saveState()
    }

    // ------------------------------------------------------------ state for the sessions (talkmode status)
    static let stateFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Talk Mode (Mantra)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    /// v10 (Marko, 15.11.2026: "please use archive the same we are using on my phones. It's AAC tiny files ... You never
    /// store the original WAV"): the microphone is taken at its own full quality (48 kHz, float), brought to 16 kHz mono in
    /// memory for the engines (the WAV is never written by Talk Mode), and every take is archived ONLY as AAC in MP4,
    /// mono, 32 kbit/s, as TTT's archive (MaEncoder.kt): takes/<time>.m4a, the newest 50.
    private(set) var lastTake = ""
    private func keepTake(_ s: [Float]) {
        DispatchQueue.global(qos: .utility).async {
            let dir = Talk.stateFile.deletingLastPathComponent().appendingPathComponent("takes")
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
            let url = dir.appendingPathComponent(f.string(from: Date()) + ".m4a")
            guard AAC.write(s, to: url) else { NSLog("[Talk] AAC archive failed: %@", url.path); return }
            let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".m4a") || $0.hasSuffix(".wav") }.sorted()
            for old in all where old.hasSuffix(".wav") { try? fm.removeItem(at: dir.appendingPathComponent(old)) }   // v9's WAVs: never kept
            for old in all.filter({ $0.hasSuffix(".m4a") }).dropLast(50) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
            DispatchQueue.main.async { self.lastTake = url.path; self.saveState() }
        }
    }

    func saveState() {
        let j: [String: Any] = ["on": on, "state": state.word, "plain": state.plain, "target": target?.name ?? "", "target_device": target?.device ?? "", "target_id": target?.id ?? "", "heard_via": heardVia,
                                "mic": device?.name ?? "", "lang": lang, "space_mode": SpaceMode.shared.on, "draft": draft, "auto_send_no_enter": autoSendNoEnter, "last_take": lastTake, "mode": auto ? "AUTO" : "MANUAL", "heard": heard, "pid": getpid(),
                                "time": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: Talk.stateFile, options: .atomic) }
    }
}
