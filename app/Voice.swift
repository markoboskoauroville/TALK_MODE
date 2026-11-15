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

    /// v13: Whisper's silence hallucinations: whole phrases, and openings it invents on room noise ("I'm going to go ...")
    static let hallucinationStarts = ["i m going to go", "im going to go", "i am going to go", "thank you for watching", "thanks for watching",
                                      "please subscribe", "subtitles by", "subtitled by", "translated by", "amara org", "see you in the next",
                                      "like and subscribe", "transcribed by", "captions by"]
    static let moreHallucinations: Set<String> = ["bye", "bye bye", "goodbye", "thank you", "oh", "ah", "the end", "you you", "silence", "no speech", "mm", "mhm"]

    /// v14: a transcript that only DESCRIBES a sound: wrapped in * ** [ ] ( ) ♪, or one interjection / onomatopoeia / repeated syllable
    static let soundWords: Set<String> = ["sigh", "sighs", "sighing", "cough", "coughs", "coughing", "whistle", "whistles", "whistling", "laugh", "laughs",
        "laughing", "laughter", "music", "applause", "clapping", "hmm", "hm", "mm", "mmm", "uh", "um", "huh", "kuf", "breathing", "sniff", "sniffs",
        "humming", "hums", "singing", "silence", "noise", "static", "inaudible", "unintelligible", "gasp", "gasps", "yawn", "yawns", "groan", "groans",
        "sneeze", "cough cough", "snoring", "clears throat", "clearing throat", "beep", "click", "clicks"]
    static func isSoundTag(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        let pairs: [(Character, Character)] = [("*", "*"), ("[", "]"), ("(", ")"), ("♪", "♪"), ("♫", "♫"), ("_", "_"), ("<", ">"), ("{", "}")]
        if let f = t.first, let l = t.last, pairs.contains(where: { $0.0 == f && $0.1 == l }) { return true }
        if t.hasPrefix("♪") || t.hasPrefix("♫") || t.hasSuffix("♪") || t.hasSuffix("♫") { return true }
        let n = norm(t)
        if n.isEmpty { return true }
        let ws = n.split(separator: " ").map(String.init)
        if soundWords.contains(n) { return true }
        if ws.allSatisfy({ soundWords.contains($0) }) && ws.count <= 4 { return true }
        // elongated interjections: oooohhhhhh, ahhh, mmmm, hmmmm, ohh
        let squeezed = String(n.filter { $0 != " " }.reduce(into: [Character]()) { if $0.last != $1 { $0.append($1) } })
        if ["o", "oh", "ho", "oho", "ah", "aha", "h", "hm", "m", "mh", "eh", "uh", "ha", "hah", "ooh", "ahh", "mm", "hmm", "ohh", "oh h", "hoh", "uhm"].contains(squeezed) { return true }
        // one syllable repeated: "kuf kuf kuf", "la la la", "na na", "ba ba ba"
        if ws.count >= 2, Set(ws).count == 1, ws[0].count <= 4 { return true }
        // a single stretched word made of one or two letters repeated ("fffff", "shhhh")
        if ws.count == 1, ws[0].count >= 4, Set(ws[0]).count <= 2, ws[0].count >= 3 { return true }
        return false
    }

    static func isNoise(_ text: String) -> Bool {
        if isSoundTag(text) { return true }
        let n = norm(text)
        if n.count < 2 || !n.contains(where: { $0.isLetter }) { return true }
        if hallucinations.contains(n) || moreHallucinations.contains(n) { return true }
        return hallucinationStarts.contains { n.hasPrefix($0) }
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

    /// v11 (Marko, 15.11.2026: "language is in my transcription blob. I can adjust everything and this is what is the
    /// default"): the language is Voice to Text's own, as its pill shows it (GET /status "language": en, hr or auto)
    static func currentLang() -> String? {
        guard let j = json("/status"), let l = j["language"] as? String, ["en", "hr", "auto"].contains(l) else { return nil }
        return l
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
        // v13: the engine's own doubt (Whisper no_speech_prob / confidence, when Voice to Text passes them on) = nothing said
        if let ns = (j["no_speech_prob"] as? Double) ?? (j["no_speech"] as? Double), ns > 0.6 { return ("", nil, via) }
        if let cf = j["confidence"] as? Double, cf > 0, cf < 0.35 { return ("", nil, via) }
        if (j["ok"] as? Bool) == true { return ((j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), nil, via) }
        let err = j["error"] as? String ?? "no text"
        if err.hasPrefix("nothing said") { return ("", nil, via) }
        return (nil, err, via)
    }

    static func viaBinary(_ wav: Data, lang: String) -> (String?, String?, String)? {
        guard FileManager.default.isExecutableFile(atPath: vttBinary) else { return nil }
        let prefs = UserDefaults(suiteName: "com.mantra.voicetotext")
        let engine = prefs?.string(forKey: "engine_" + (lang == "auto" ? "hr" : lang)) ?? "assemblyai"
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

/// v8: one engine of Voice to Text, as the ENGINES panel shows it (Marko, 15.11.2026: "luxurious changing of engines ...
/// remote control for our VOX application ... the stars ratings, timing and everything, and the credits")
struct EngineRow: Identifiable, Hashable {
    let id: String
    let label: String          // "Deepgram · 0.9 s · ★★★★☆" for the language
    let short: String          // the name alone
    let stars: Int             // 0...5
    let quality: Int?          // percent
    let secs: Double?          // median time of a take
    let available: Bool
    let selected: Bool         // the engine of this language now
    let credit: String         // what is known of its credit, in words
    let route: String          // "Frankfurt" or "this Mac"
}

extension Hearing {
    static func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> [String: Any]? {
        guard let url = URL(string: api + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.httpMethod = method
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var j: [String: Any]?
        URLSession.shared.dataTask(with: r) { d, _, _ in
            if let d { j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return j
    }

    static func hours(_ s: Int) -> String {
        if s >= 3600 { let h = Double(s) / 3600; return h >= 10 ? "\(Int(h.rounded())) h" : String(format: "%.1f h", h) }
        return "\(max(0, s / 60)) min"
    }

    static func creditText(_ c: [String: Any], local: Bool, paid: Bool) -> String {
        if local { return "this Mac · free" }
        var parts: [String] = []
        let reset = c["reset"] as? String ?? ""
        if paid { parts.append(String(format: "paid · $%.2f an hour", c["price_per_hour"] as? Double ?? 0)) }
        else if let left = c["left_seconds"] as? Int, let free = c["free_seconds"] as? Int {
            switch reset {
            case "oneOff": parts.append("trial credit · \(hours(left)) left of \(hours(free))")
            case "daily": parts.append("free \(hours(free)) a day · \(hours(left)) left today")
            case "monthly": parts.append("free \(hours(free)) a month · \(hours(left)) left")
            case "hourly": parts.append("free \(hours(free)) an hour · \(hours(left)) left")
            default: parts.append("free · \(hours(left)) left")
            }
        }
        if let k = c["keys"] as? Int { parts.append(k == 1 ? "1 key" : "\(k) keys") }
        return parts.joined(separator: " · ")
    }

    /// every engine for the language, from Voice to Text v26+ (older: without credit)
    static func engines(lang: String) -> [EngineRow]? {
        guard let list = json("/engines")?["engines"] as? [[String: Any]] else { return nil }
        let chosen = UserDefaults(suiteName: "com.mantra.voicetotext")?.string(forKey: "engine_" + lang)
        return list.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            let st = e["stats_" + lang] as? [String: Any] ?? [:]
            let label = (lang == "hr" ? e["label_hr"] : e["label"]) as? String ?? id
            let starText = st["stars"] as? String ?? ""
            let local = e["local"] as? Bool ?? false, paid = e["paid"] as? Bool ?? false
            let c = e["credit"] as? [String: Any] ?? [:]
            let sel = (e["selected_" + lang] as? Bool) ?? (chosen == id)
            return EngineRow(id: id, label: label, short: label.components(separatedBy: " · ").first ?? label,
                             stars: starText.filter { $0 == "★" }.count, quality: st["quality_pct"] as? Int,
                             secs: (st["median_secs"] as? Double) ?? (st["median_secs"] as? Int).map(Double.init),
                             available: e["available"] as? Bool ?? true, selected: sel,
                             credit: creditText(c, local: local, paid: paid),
                             route: local ? "this Mac" : ((c["frankfurt"] as? Bool) == true ? "Frankfurt" : "direct"))
        }
    }

    /// makes it the engine of that language in Voice to Text (POST /engines/select, v26+)
    static func select(_ id: String, lang: String) -> (Bool, String) {
        guard let j = json("/engines/select", method: "POST", body: ["id": id, "lang": lang]) else { return (false, "Voice to Text does not answer") }
        if (j["ok"] as? Bool) == true { return (true, j["label"] as? String ?? id) }
        return (false, j["error"] as? String ?? "Voice to Text v26 or newer is needed")
    }

    /// BEST: stars first, then the faster; STARS: quality; TIME: the fastest first (no data last)
    static func sorted(_ rows: [EngineRow], by: String) -> [EngineRow] {
        func t(_ r: EngineRow) -> Double { r.secs ?? 999 }
        func q(_ r: EngineRow) -> Int { r.quality ?? -1 }
        let a = rows.filter(\.available), b = rows.filter { !$0.available }
        let s: [EngineRow]
        switch by {
        case "stars": s = a.sorted { q($0) != q($1) ? q($0) > q($1) : t($0) < t($1) }
        case "time": s = a.sorted { t($0) != t($1) ? t($0) < t($1) : q($0) > q($1) }
        default: s = a.sorted { $0.stars != $1.stars ? $0.stars > $1.stars : t($0) != t($1) ? t($0) < t($1) : q($0) > q($1) }
        }
        return s + b
    }
}
