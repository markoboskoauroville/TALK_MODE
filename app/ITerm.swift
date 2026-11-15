// ITerm.swift: the Claude Code sessions are iTerm2 sessions. Listed and written to by iTerm2's AppleScript: `write text`
// goes to that one session, wherever it is, without bringing anything to the front and without a keystroke into any
// other app. The text first (newline NO), 0.6 s, then Return (the proven way, ELEVATE_MEDIA_MONITOR tools/embrain.py:
// text and Return together can land as a pasted line that is not sent).
import Foundation

struct TermSession: Hashable, Identifiable {
    let id: String          // iTerm2's unique id of the session
    let name: String        // the tab name as iTerm2 shows it, the status glyph taken off
    let tty: String
    var active: Date        // the last output on its tty (the device's modification time)
}

enum ITerm {
    /// osascript with the arguments as argv (no quoting of the text inside the script)
    @discardableResult
    static func osa(_ script: String, _ args: [String] = [], timeout: Double = 8) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static let listScript = """
    on run argv
      if application "iTerm2" is not running then return ""
      set sepTab to character id 9
      set sepLine to character id 10
      set out to ""
      tell application "iTerm2"
        repeat with aWin in windows
          repeat with aTab in tabs of aWin
            repeat with aSes in sessions of aTab
              set out to out & (id of aSes) & sepTab & (name of aSes) & sepTab & (tty of aSes) & sepLine
            end repeat
          end repeat
        end repeat
      end tell
      return out
    end run
    """

    static let writeScript = """
    on run argv
      set sid to item 1 of argv
      set msg to item 2 of argv
      tell application "iTerm2"
        repeat with aWin in windows
          repeat with aTab in tabs of aWin
            repeat with aSes in sessions of aTab
              if (id of aSes) is sid then
                tell aSes to write text msg newline NO
                delay 0.6
                tell aSes to write text "" newline YES
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "none"
    end run
    """

    static func clean(_ name: String) -> String {
        var s = Substring(name)
        while let c = s.first, !(c.isLetter || c.isNumber) { s = s.dropFirst() }
        return String(s).trimmingCharacters(in: .whitespaces)
    }

    static func list() -> [TermSession] {
        guard let out = osa(listScript) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 3 else { return nil }
            let m = (try? FileManager.default.attributesOfItem(atPath: c[2]))?[.modificationDate] as? Date ?? .distantPast
            return TermSession(id: c[0], name: clean(c[1]), tty: c[2], active: m)
        }
    }

    /// the default target: the most recently active session whose name starts with "mac23" (this Mac's sessions), else
    /// the most recently active session whose name looks like a Claude Code session, else the most recently active one
    static func pickDefault(_ all: [TermSession]) -> TermSession? {
        let byActive = all.sorted { $0.active > $1.active }
        if let s = byActive.first(where: { $0.name.lowercased().hasPrefix("mac23") }) { return s }
        if let s = byActive.first(where: { $0.name.range(of: #"^mac\d+_"#, options: .regularExpression) != nil }) { return s }
        return byActive.first
    }

    /// the words, then Return; true when the session was found
    static func write(_ text: String, to sessionID: String) -> Bool {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !one.isEmpty else { return false }
        return osa(writeScript, [sessionID, one], timeout: 10) == "ok"
    }
}
