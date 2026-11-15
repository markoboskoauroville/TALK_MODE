// Talk.swift: the conversation. Marko talks, pauses; his words go to the chosen Claude Code session; Claude answers aloud
// through the voice (every reply ends with langsay); while the voice talks Talk Mode is deaf; then it listens again.
// In typing mode the ears stay open only for the switch phrase ("real time talk mode"), short utterances only.
import AppKit
import Foundation

enum TalkState: Equatable {
    case typing, listening, hearing, writing, thinking, speaking, recording, voiceDown, noMic(String), noTarget, manual, sending

    var word: String {
        switch self {
        case .typing: return "TYPING MODE"
        case .listening: return "LISTENING"
        case .hearing: return "HEARING YOU"
        case .writing: return "WRITING IT DOWN"
        case .thinking: return "CLAUDE IS THINKING"
        case .speaking: return "SPEAKING"
        case .recording: return "PAUSED · RECORDING"
        case .voiceDown: return "VOICE ENGINE IS DOWN"
        case .noMic: return "NO MICROPHONE"
        case .noTarget: return "NO SESSION"
        case .manual: return "RECORDING…"
        case .sending: return "SENDING"
        }
    }
}

final class Talk: ObservableObject {
    static let shared = Talk()

    @Published private(set) var on: Bool
    @Published private(set) var state: TalkState = .typing
    @Published private(set) var heard = ""
    @Published private(set) var note = ""
    @Published private(set) var levelDB: Float = -90
    @Published private(set) var folders: [DeviceFolder] = []
    @Published private(set) var target: Target?
    @Published private(set) var heardVia = ""
    @Published private(set) var scanning = false
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var device: InputDevice?
    @Published var lang: String { didSet { UserDefaults.standard.set(lang, forKey: "lang"); saveState() } }
    @Published var pause: Double { didSet { UserDefaults.standard.set(pause, forKey: "pause"); work.async { self.vad.pause = self.pause } } }
    @Published var minLength: Double { didSet { UserDefaults.standard.set(minLength, forKey: "minLength"); work.async { self.vad.minLength = self.minLength } } }

    /// v5 (Marko, 15.11.2026: "how good is each engine and how fast is each engine in the engine name everywhere"): the engine of each
    /// language with its median time and stars, read from Voice to Text's /engines ("Deepgram · 1.0 s · ★★★★☆")
    @Published private(set) var earsLabel: [String: String] = [:]
    func refreshEars() {
        DispatchQueue.global().async {
            let l = Hearing.engineLabels()
            DispatchQueue.main.async { if !l.isEmpty { self.earsLabel = l } }
        }
    }
    func earsText(_ code: String) -> String { earsLabel[code] ?? "Voice to Text not answering" }

    /// v6: Space / SEND NOW. `manual` (main) is the push-to-talk take; manualOn/manualBuf/forcedFlag live on the work queue
    @Published private(set) var manual = false
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
        lang = d.string(forKey: "lang") ?? "en"
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
        let language = DispatchQueue.main.sync { self.lang }
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
        if Phrase.isNoise(text) { state = on ? .listening : .typing; return }
        send(text)
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

    func openEngines() { enginesOpen = true; engineNote = "reading Voice to Text…"; loadEngines(moveCursor: true) }
    func closeEngines() { enginesOpen = false }

    func loadEngines(moveCursor: Bool = false) {
        let l = lang, by = engineSort
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
        let l = lang
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

    /// v9: every utterance that goes to the ears is kept as takes/<time>.wav (16 kHz mono), the newest 20 only
    private(set) var lastWav = ""
    private func keepTake(_ s: [Float]) {
        let dir = Talk.stateFile.deletingLastPathComponent().appendingPathComponent("takes")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = dir.appendingPathComponent(f.string(from: Date()) + ".wav")
        guard (try? WAV.data(s).write(to: url)) != nil else { return }
        let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        for old in all.dropLast(20) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        DispatchQueue.main.async { self.lastWav = url.path; self.saveState() }
    }

    func saveState() {
        let j: [String: Any] = ["on": on, "state": state.word, "target": target?.name ?? "", "target_device": target?.device ?? "", "target_id": target?.id ?? "", "heard_via": heardVia,
                                "mic": device?.name ?? "", "lang": lang, "last_wav": lastWav, "mode": auto ? "AUTO" : "MANUAL", "heard": heard, "pid": getpid(),
                                "time": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: Talk.stateFile, options: .atomic) }
    }
}
