// Talk.swift: the conversation. Marko talks, pauses; his words go to the chosen Claude Code session; Claude answers aloud
// through the voice (every reply ends with langsay); while the voice talks Talk Mode is deaf; then it listens again.
// In typing mode the ears stay open only for the switch phrase ("real time talk mode"), short utterances only.
import AppKit
import Foundation

enum TalkState: Equatable {
    case typing, listening, hearing, writing, thinking, speaking, recording, voiceDown, noMic(String), noTarget

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
    @Published private(set) var sessions: [TermSession] = []
    @Published private(set) var target: TermSession?
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var device: InputDevice?
    @Published var lang: String { didSet { UserDefaults.standard.set(lang, forKey: "lang"); saveState() } }
    @Published var pause: Double { didSet { UserDefaults.standard.set(pause, forKey: "pause"); work.async { self.vad.pause = self.pause } } }
    @Published var minLength: Double { didSet { UserDefaults.standard.set(minLength, forKey: "minLength"); work.async { self.vad.minLength = self.minLength } } }

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
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshSessions() }
        saveState()
    }

    private func startEars() {
        do { try ears.start(device: device); note = "" }
        catch { state = .noMic(error.localizedDescription); note = "Microphone: \(error.localizedDescription)" }
    }

    // ------------------------------------------------------------ audio (work queue)
    private func samples(_ s: [Float]) {
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
        let talking = DispatchQueue.main.sync { self.on }
        if !talking && span > 4 { DispatchQueue.main.async { self.voiceEnded() }; return }   // typing mode: only short phrases
        DispatchQueue.main.async { if self.on { self.state = .writing } }
        let language = DispatchQueue.main.sync { self.lang }
        hearQ.async {
            let r = Voice.hear(s, lang: talking ? language : "en")
            DispatchQueue.main.async { self.handle(r.text, error: r.error) }
        }
    }

    // ------------------------------------------------------------ main thread
    private func voiceStarted() { if on, state == .listening { state = .hearing } }
    private func voiceEnded() { if on, state == .hearing { state = .listening } }

    private func handle(_ text: String?, error: String?) {
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
        case .repeatLast where on:
            heard = text; note = "saying the last answer again"
            Voice.replay()
            state = .listening
            return
        default: break
        }
        guard on else { return }
        if Phrase.isNoise(text) { state = .listening; return }
        send(text)
    }

    func send(_ text: String) {
        guard let t = target else { state = .noTarget; note = "Choose the session in ①"; return }
        heard = text
        state = .thinking
        thinkingSince = Date()
        DispatchQueue.global().async {
            Voice.seen()                                   // REPLAY starts from the answer to these words
            let ok = ITerm.write(text, to: t.id)
            DispatchQueue.main.async {
                if !ok {
                    self.note = "\(t.name) was not found: choose the session again"
                    self.state = .noTarget
                    self.refreshSessions()
                } else { self.note = "" }
                self.saveState()
            }
        }
    }

    /// the state follows the voice and the gate, 7 times a second
    private func update() {
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
    func repeatLast() { Voice.replay() }

    // ------------------------------------------------------------ sessions and microphones
    func refreshSessions() {
        DispatchQueue.global().async {
            let all = ITerm.list()
            DispatchQueue.main.async {
                self.sessions = all.sorted { $0.name.lowercased() < $1.name.lowercased() }
                let d = UserDefaults.standard
                if let cur = self.target, let same = all.first(where: { $0.id == cur.id }) { self.target = same; return }
                if let id = d.string(forKey: "targetID"), let s = all.first(where: { $0.id == id }) { self.target = s }
                else if let n = d.string(forKey: "targetName"), let s = all.first(where: { $0.name == n }) { self.target = s }
                else { self.target = ITerm.pickDefault(all) }
                if self.on, self.state == .noTarget, self.target != nil { self.state = .listening }
                self.saveState()
            }
        }
    }

    func choose(_ s: TermSession) {
        target = s
        UserDefaults.standard.set(s.id, forKey: "targetID")
        UserDefaults.standard.set(s.name, forKey: "targetName")
        if on, state == .noTarget { state = .listening }
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

    func saveState() {
        let j: [String: Any] = ["on": on, "state": state.word, "target": target?.name ?? "", "target_tty": target?.tty ?? "",
                                "mic": device?.name ?? "", "lang": lang, "heard": heard, "pid": getpid(),
                                "time": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: Talk.stateFile, options: .atomic) }
    }
}
