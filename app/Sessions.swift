// Sessions.swift: every open Claude Code session, in a folder per DEVICE (Marko, 15.11.2026: "list all my open session by
// folders. Folders are meaning in which device is the session. So I open the devices and then I can talk to any of my
// sessions" ... "the session are ordered by activity. So last active session is at the top").
//
//   MacBook Pro    iTerm2 tabs whose tty runs a Claude Code process (~/.claude/sessions/<pid>.json); activity = the
//                  session's transcript (last prompt or reply); typed with iTerm2 `write text`.
//   chromium-vm    tmux sessions on the VM (ssh chromium-vm); activity = tmux's session_activity; typed with
//                  `tmux send-keys -l`, then Enter.
//   Nothing, Pixel Claude Code in Termux (adb: a `claude` process); shown greyed: it runs without tmux, and adb `input`
//                  would type into whatever app is on the phone's screen. No safe way in from here yet.
//   Cloud          claude.ai/code sessions that wrote to this Mac's hub INBOX in the last two days; greyed.
// Folders are ordered by their most recent session, sessions inside by their last activity, newest first.
import Foundation

enum Kind: String { case mac, vm, phone, cloud }

struct Target: Hashable, Identifiable {
    let kind: Kind
    let device: String
    let key: String            // iTerm2 session id · tmux session name · adb serial · cloud session id
    let name: String
    let detail: String         // the folder or the running command
    let active: Date?
    let deliverable: Bool
    let reason: String
    var id: String { kind.rawValue + ":" + key }
}

struct DeviceFolder: Identifiable, Hashable {
    let name: String
    let online: Bool
    let note: String
    var sessions: [Target]
    var id: String { name }
    var latest: Date? { sessions.compactMap(\.active).max() }
}

enum Shell {
    /// a program with a deadline; (exit status, stdout)
    static func run(_ exe: String, _ args: [String], timeout: Double = 8) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        do { try p.run() } catch { return (-1, "") }
        var data = Data()
        let reader = DispatchQueue(label: "shell.read")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.2); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        _ = done.wait(timeout: .now() + 2)
        return (p.isRunning ? -1 : p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// one word for a remote shell: 'it''s' quoting
    static func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum Roster {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let adb = home + "/Library/Android/sdk/platform-tools/adb"
    static let vmHost = "chromium-vm"
    /// the phones by their Tailscale adb address (MANTRA_MANIFEST devices-see-each-other.md), shown even when not connected
    static let knownPhones: [(serial: String, name: String)] = [("100.67.149.40:5555", "Nothing Phone"), ("100.70.23.53:5555", "Pixel 7")]

    static func ago(_ d: Date?) -> String {
        guard let d else { return "activity unknown" }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "active now" }
        if s < 3600 { return "active \(s / 60) min ago" }
        if s < 86400 { return "active \(s / 3600) h ago" }
        return "active \(s / 86400) d ago"
    }

    /// every device at once (each source has its own deadline); folders by their newest session
    static func scan() -> [DeviceFolder] {
        var mac: DeviceFolder?, vm: DeviceFolder?, ph: [DeviceFolder] = [], cl: DeviceFolder?
        let g = DispatchGroup(), q = DispatchQueue.global(qos: .utility)
        q.async(group: g) { mac = macFolder() }
        q.async(group: g) { vm = vmFolder() }
        q.async(group: g) { ph = phoneFolders() }
        q.async(group: g) { cl = cloudFolder() }
        g.wait()
        let all = [mac, vm, cl].compactMap { $0 } + ph
        return all.sorted { a, b in
            switch (a.latest, b.latest) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.online && !b.online
            }
        }
    }

    static func sortByActivity(_ s: [Target]) -> [Target] {
        s.sorted { ($0.active ?? .distantPast) > ($1.active ?? .distantPast) }
    }

    // ------------------------------------------------------------ this Mac
    struct LocalClaude { let pid: Int32; let sid: String; let name: String; let cwd: String; let status: String; let bridge: String }

    static func localClaudes() -> [LocalClaude] {
        let dir = home + "/.claude/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { f in
            guard let d = FileManager.default.contents(atPath: dir + "/" + f),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let pid = (j["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 else { return nil }
            return LocalClaude(pid: pid, sid: j["sessionId"] as? String ?? "", name: j["name"] as? String ?? "",
                               cwd: j["cwd"] as? String ?? "", status: j["status"] as? String ?? "",
                               bridge: j["bridgeSessionId"] as? String ?? "")
        }
    }

    /// the newest change of the session's transcript: its last prompt or reply
    static func transcriptTime(_ sid: String) -> Date? {
        guard !sid.isEmpty else { return nil }
        let root = home + "/.claude/projects"
        for p in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let f = "\(root)/\(p)/\(sid).jsonl"
            if let m = (try? FileManager.default.attributesOfItem(atPath: f))?[.modificationDate] as? Date { return m }
        }
        return nil
    }

    static func macFolder() -> DeviceFolder {
        let claudes = localClaudes()
        var ttyOf: [Int32: String] = [:]
        if !claudes.isEmpty {
            let (_, out) = Shell.run("/bin/ps", ["-o", "pid=,tty=", "-p", claudes.map { String($0.pid) }.joined(separator: ",")], timeout: 3)
            for line in out.split(separator: "\n") {
                let c = line.split(separator: " ", omittingEmptySubsequences: true)
                if c.count >= 2, let pid = Int32(c[0]), c[1] != "??" { ttyOf[pid] = "/dev/" + c[1] }
            }
        }
        let tabs = ITerm.list()
        var out: [Target] = []
        for c in claudes {
            guard let tty = ttyOf[c.pid], let tab = tabs.first(where: { $0.tty == tty }) else { continue }
            let folder = (c.cwd as NSString).lastPathComponent
            out.append(Target(kind: .mac, device: "MacBook Pro", key: tab.id, name: c.name.isEmpty ? tab.name : c.name,
                              detail: [folder, c.status].filter { !$0.isEmpty }.joined(separator: " · "),
                              active: transcriptTime(c.sid) ?? tab.active, deliverable: true, reason: ""))
        }
        return DeviceFolder(name: "MacBook Pro", online: true, note: out.isEmpty ? "no Claude Code session in iTerm2" : "",
                            sessions: sortByActivity(out))
    }

    // ------------------------------------------------------------ chromium-vm
    static func vmFolder() -> DeviceFolder {
        let cmd = "tmux list-panes -a -F '#{session_name}|#{session_activity}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null; echo TALKMODE-OK"
        let (st, out) = Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", vmHost, cmd], timeout: 9)
        guard st == 0, out.contains("TALKMODE-OK") else {
            return DeviceFolder(name: "chromium-vm", online: false, note: "not reachable over ssh", sessions: [])
        }
        var seen = Set<String>(), list: [Target] = []
        for line in out.split(separator: "\n") where line.contains("|") {
            let c = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 4, !seen.contains(c[0]) else { continue }
            seen.insert(c[0])
            let when = Double(c[1]).map { Date(timeIntervalSince1970: $0) }
            list.append(Target(kind: .vm, device: "chromium-vm", key: c[0], name: c[0],
                               detail: c[2] + " · " + (c[3] as NSString).lastPathComponent, active: when, deliverable: true, reason: ""))
        }
        return DeviceFolder(name: "chromium-vm", online: true, note: list.isEmpty ? "no tmux session" : "", sessions: sortByActivity(list))
    }

    // ------------------------------------------------------------ the phones
    static func phoneFolders() -> [DeviceFolder] {
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            return knownPhones.map { DeviceFolder(name: $0.name, online: false, note: "adb is not installed", sessions: []) }
        }
        let (_, devs) = Shell.run(adb, ["devices", "-l"], timeout: 5)
        var connected: [(String, String)] = []                       // serial, name
        for line in devs.split(separator: "\n").dropFirst() {
            let c = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard c.count >= 2, c[1] == "device" else { continue }
            let model = c.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? c[0]
            let name = knownPhones.first(where: { $0.serial == c[0] })?.name
                ?? (model.lowercased().contains("pixel") ? model.replacingOccurrences(of: "_", with: " ") : model.hasPrefix("A1") ? "Nothing Phone" : model)
            if !connected.contains(where: { $0.1 == name }) { connected.append((c[0], name)) }
        }
        var out: [DeviceFolder] = []
        for (serial, name) in connected {
            let (_, ps) = Shell.run(adb, ["-s", serial, "shell", "ps -A -o PID,NAME"], timeout: 6)
            let pids = ps.split(separator: "\n").compactMap { l -> String? in
                let c = l.split(separator: " ", omittingEmptySubsequences: true)
                return c.count >= 2 && c[1] == "claude" ? String(c[0]) : nil
            }
            let s = pids.map { pid in
                Target(kind: .phone, device: name, key: serial + "#" + pid, name: "Claude Code in Termux (pid \(pid))", detail: serial,
                       active: nil, deliverable: false, reason: "no safe way to type into Termux yet")
            }
            out.append(DeviceFolder(name: name, online: true,
                                    note: s.isEmpty ? "no Claude Code running" : "Termux runs Claude Code without tmux; adb would type into whatever app is on the screen",
                                    sessions: s))
        }
        for k in knownPhones where !out.contains(where: { $0.name == k.name }) {
            out.append(DeviceFolder(name: k.name, online: false, note: "not connected (adb over Tailscale)", sessions: []))
        }
        return out
    }

    // ------------------------------------------------------------ cloud sessions
    static func cloudFolder() -> DeviceFolder {
        let inbox = home + "/Developer/claude-code/INBOX"
        let mine = Set(localClaudes().map(\.bridge))
        let fm = FileManager.default
        var list: [Target] = []
        for f in (try? fm.contentsOfDirectory(atPath: inbox)) ?? [] where f.hasPrefix("session_") && f.hasSuffix(".md") {
            let sid = String(f.dropLast(3))
            guard !mine.contains(sid),
                  let m = (try? fm.attributesOfItem(atPath: inbox + "/" + f))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(m) < 2 * 86400 else { continue }
            list.append(Target(kind: .cloud, device: "Cloud", key: sid, name: sid, detail: "hub INBOX", active: m,
                               deliverable: false, reason: "can't be typed into from here"))
        }
        return DeviceFolder(name: "Cloud", online: true, note: list.isEmpty ? "no cloud session in the last two days" : "claude.ai/code sessions: can't be typed into from here",
                            sessions: sortByActivity(list))
    }

    /// the default: the most recently active Mac session whose name starts with "mac23", else the newest Mac session
    static func pickDefault(_ folders: [DeviceFolder]) -> Target? {
        let mac = folders.first { $0.name == "MacBook Pro" }?.sessions ?? []
        return mac.first { $0.name.lowercased().hasPrefix("mac23") } ?? mac.first
            ?? folders.flatMap(\.sessions).first { $0.deliverable }
    }
}

enum Deliver {
    /// the words, then Return, into that one session; (delivered, what went wrong)
    static func send(_ text: String, to t: Target) -> (Bool, String) {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !one.isEmpty else { return (false, "nothing to send") }
        switch t.kind {
        case .mac:
            return ITerm.write(one, to: t.key) ? (true, "") : (false, "\(t.name) was not found in iTerm2")
        case .vm:
            let n = Shell.sq(t.key)
            let cmd = "tmux send-keys -t \(n) -l \(Shell.sq(one)) && sleep 0.6 && tmux send-keys -t \(n) Enter"
            let (st, _) = Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", Roster.vmHost, cmd], timeout: 12)
            return st == 0 ? (true, "") : (false, "chromium-vm did not take it (tmux \(t.key))")
        case .phone, .cloud:
            return (false, t.reason)
        }
    }
}
