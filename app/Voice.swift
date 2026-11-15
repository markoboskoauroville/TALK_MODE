// Voice.swift: MANTRA_VOICE at 127.0.0.1:8837 is the only ear and the only mouth (API.md). /hear writes down what Marko
// said; /speaking says whether the voice is talking (then Talk Mode is deaf, no echo); /speak/replay says the last reply
// again; /speak/seen marks what was read as heard, so REPLAY starts from the reply after his last words.
// The gate also closes while a recording is open (MicGuard: ~/.voice/recording.flag, Voice to Text's take-open).
import Foundation

enum Voice {
    static let base = "http://127.0.0.1:8837"

    /// one synchronous request (called off the main thread)
    static func request(_ path: String, method: String = "GET", body: Data? = nil, type: String = "application/json",
                        timeout: Double = 3) -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if let body { r.httpBody = body; r.setValue(type, forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            if let d, (resp as? HTTPURLResponse)?.statusCode ?? 0 < 500 {
                out = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return out
    }

    static func post(_ path: String, _ json: [String: Any] = [:]) -> [String: Any]? {
        request(path, method: "POST", body: try? JSONSerialization.data(withJSONObject: json))
    }

    /// speech to text; lang "en" or "hr"
    static func hear(_ samples: [Float], lang: String) -> (text: String?, error: String?) {
        guard let j = request("/hear?lang=\(lang)", method: "POST", body: WAV.data(samples), type: "audio/wav", timeout: 60) else {
            return (nil, "the voice engine does not answer")
        }
        if let t = j["text"] as? String { return (t.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        return (nil, (j["error"] as? String) ?? "no text")
    }

    /// is the voice talking now (a reading that is on and not paused)
    static func speaking() -> (on: Bool, reachable: Bool) {
        guard let j = request("/speaking", timeout: 1) else { return (false, false) }
        let on = (j["on"] as? Bool) ?? false
        let paused = (j["paused"] as? Bool) ?? false
        return (on && !paused, true)
    }

    static func say(_ text: String) { DispatchQueue.global().async { _ = post("/speak", ["text": text]) } }
    static func stop() { DispatchQueue.global().async { _ = post("/speak/stop") } }
    static func replay() { DispatchQueue.global().async { _ = post("/speak/replay") } }
    static func seen() { _ = post("/speak/seen") }

    /// the voice is down: start it (Marko, 2.11.2026: "Please don't ask me anymore to run anything."), at most once a minute
    private static var lastStart = Date.distantPast
    static func startIfDown() {
        guard Date().timeIntervalSince(lastStart) > 60 else { return }
        lastStart = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSString(string: "~/.local/bin/voicectl").expandingTildeInPath)
        p.arguments = ["start"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// When Talk Mode must not listen: the voice talks (and 400 ms after), or a recording is open.
final class Gate {
    static let shared = Gate()
    private let lock = NSLock()
    private var _speaking = false
    private var _speakEnd = Date.distantPast
    private var _recording = false
    private var _reachable = true
    var tail = 0.4

    var speaking: Bool { lock.lock(); defer { lock.unlock() }; return _speaking }
    var recording: Bool { lock.lock(); defer { lock.unlock() }; return _recording }
    var reachable: Bool { lock.lock(); defer { lock.unlock() }; return _reachable }
    /// closed: no sample reaches the detector
    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _speaking || _recording || Date().timeIntervalSince(_speakEnd) < tail
    }

    /// one poll: /speaking every 150 ms, the recording flags every poll (files are cheap)
    func poll() {
        let s = Voice.speaking()
        let rec = Gate.pidFileAlive("~/.voice/recording.flag")
            || Gate.pidFileAlive("~/Library/Application Support/Voice to Text (Mantra)/take-open")
        lock.lock()
        if _speaking && !s.on { _speakEnd = Date() }
        _speaking = s.on; _reachable = s.reachable; _recording = rec
        lock.unlock()
    }

    func startPolling() {
        Thread.detachNewThread { [weak self] in
            while true {
                guard let me = self else { return }
                me.poll()
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    static func pidFileAlive(_ path: String) -> Bool {
        let p = NSString(string: path).expandingTildeInPath
        guard let s = try? String(contentsOfFile: p, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}

/// The spoken switches. Whisper writes "Real-time talk mode." or "realtime talk mode"; the words are compared without
/// punctuation, and a phrase counts only when it is (almost) all that was said, so a sentence that mentions "typing mode"
/// still goes to Claude.
enum Phrase {
    case on, off, repeatLast, none

    static let onWords = ["real time talk mode", "realtime talk mode", "talk mode on", "start talk mode", "real time chat mode"]
    static let offWords = ["typing mode", "talk mode off", "stop talk mode", "end talk mode", "typing mode on"]
    static let repeatWords = ["say that again", "repeat that", "repeat please", "please repeat", "can you repeat that",
                              "repeat the last answer", "say it again", "what did you say"]
    /// what Whisper writes for silence or a cough
    static let hallucinations: Set<String> = ["", "you", "thank you for watching", "thanks for watching",
                                              "uh", "um", "hmm", "music", "applause", "subtitles by the amara org community"]

    static func norm(_ s: String) -> String {
        let low = s.lowercased().replacingOccurrences(of: "-", with: " ")
        let kept = low.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func classify(_ text: String) -> Phrase {
        let n = norm(text)
        let words = n.split(separator: " ").count
        func hit(_ list: [String]) -> Bool {
            list.contains { p in n.contains(p) && words <= p.split(separator: " ").count + 3 }
        }
        if hit(offWords) { return .off }
        if hit(onWords) { return .on }
        if hit(repeatWords) { return .repeatLast }
        return .none
    }

    static func isNoise(_ text: String) -> Bool {
        let n = norm(text)
        return n.count < 2 || hallucinations.contains(n)
    }
}

/// The ears are Marko's own: Voice to Text (Mantra)'s engine for the language, through its route (Frankfurt, key ring),
/// asked on its local API (127.0.0.1:8865, POST /hear, v23+). Marko, 15.11.2026: "It needs to use my engine basically,
/// voice to text, the same one I'm using for transcription". When the app does not answer: its own binary (`--hear`, the
/// engine read from its settings); only when Voice to Text is not on this Mac at all: MANTRA_VOICE /hear, and the HEARD
/// line says so.
enum Hearing {
    static let api = "http://127.0.0.1:8865"
    static let vttBinary = "/Applications/Voice to Text (Mantra).app/Contents/MacOS/Voice to Text (Mantra)"

    /// (text, error, how: "Deepgram EN · Frankfurt · 1.1 s")
    static func hear(_ samples: [Float], lang: String) -> (text: String?, error: String?, via: String) {
        let wav = WAV.data(samples)
        if let r = viaAPI(wav, lang: lang) { return r }
        if let r = viaBinary(wav, lang: lang) { return r }
        let v = Voice.hear(samples, lang: lang)
        return (v.text, v.error, "MANTRA_VOICE Whisper (Voice to Text did not answer)")
    }

    static func viaAPI(_ wav: Data, lang: String) -> (String?, String?, String)? {
        guard let url = URL(string: api + "/hear?lang=\(lang)") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 90)
        r.httpMethod = "POST"; r.httpBody = wav; r.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let sem = DispatchSemaphore(value: 0)
        var j: [String: Any]?, code = 0
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let d { j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 95)
        guard code == 200, let j, j["text"] != nil else { return nil }      // 404: Voice to Text before v23
        let via = label(j["engine"] as? String, j["route"] as? String, j["secs"] as? Double)
        if (j["ok"] as? Bool) == true { return ((j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), nil, via) }
        let err = j["error"] as? String ?? "no text"
        if err.hasPrefix("nothing said") { return ("", nil, via) }
        return (nil, err, via)
    }

    static func viaBinary(_ wav: Data, lang: String) -> (String?, String?, String)? {
        guard FileManager.default.isExecutableFile(atPath: vttBinary) else { return nil }
        let prefs = UserDefaults(suiteName: "com.mantra.voicetotext")
        let engine = prefs?.string(forKey: "engine_" + lang) ?? "assemblyai"
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("talkmode-\(UUID().uuidString).wav")
        guard (try? wav.write(to: f)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: f) }
        let (st, out) = Shell.run(vttBinary, ["--hear", engine, f.path, lang], timeout: 90)
        guard st == 0 else { return nil }
        var text: String?, err: String?, route = "", head = engine
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("FAILED:") { err = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("route:") { route = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if text == nil, let r = line.range(of: ": "), line.first?.isNumber == true {
                head = String(line[..<r.lowerBound]).split(separator: " ").dropFirst(2).joined(separator: " ")
                text = String(line[r.upperBound...])
            }
        }
        if text == nil && err == nil { return nil }
        let via = label(head, route == "-" ? "" : route, nil) + " (Voice to Text not running)"
        if let e = err, e.hasPrefix("nothing said") { return ("", nil, via) }
        return (text, err, via)
    }

    /// "Deepgram EN · 1.0 s · ★★★★☆ · now 1.3 s · Frankfurt …": the engine's own name carries its median time and stars (Voice to
    /// Text v24+), "now" is this take
    static func label(_ engine: String?, _ route: String?, _ secs: Double?) -> String {
        [engine ?? "", secs.map { String(format: "now %.1f s", $0) } ?? "", route ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// v5: ["en": "Deepgram · 1.0 s · ★★★★☆", "hr": "..."] for the engine picked for each language in Voice to Text, from GET /engines
    static func engineLabels() -> [String: String] {
        guard let url = URL(string: api + "/engines") else { return [:] }
        var r = URLRequest(url: url, timeoutInterval: 4)
        r.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var j: [String: Any]?
        URLSession.shared.dataTask(with: r) { d, _, _ in
            if let d { j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        guard let list = j?["engines"] as? [[String: Any]] else { return [:] }
        let prefs = UserDefaults(suiteName: "com.mantra.voicetotext")
        var out: [String: String] = [:]
        for (code, key) in [("en", "label"), ("hr", "label_hr")] {
            let id = prefs?.string(forKey: "engine_" + code) ?? "assemblyai"
            if let e = list.first(where: { $0["id"] as? String == id }), let t = e[key] as? String { out[code] = t }
        }
        return out
    }
}
