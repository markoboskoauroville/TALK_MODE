// SystemAudioSwiftUI.swift (kit system-audio): the same two lines as SystemAudioView, for SwiftUI windows (Talk Mode).
// Copy unchanged next to SystemAudio.swift. MICROPHONE <name ▾> <level> <warning> · SPEAKER <name ▾> <warning>, the status line
// "Output: ADAM Audio D3V → X" and UNDO. A click on a line opens its picker (SystemAudio.popMenu). Names wrap, never cut.
import SwiftUI

struct SystemAudioLines: View {
    @ObservedObject var live = SystemAudioLive.shared
    var size: CGFloat = 15
    static let green = Color(red: 0.2, green: 0.82, blue: 0.48)
    static let amber = Color(red: 0.94, green: 0.63, blue: 0.19)
    static let dim = Color(red: 0.56, green: 0.56, blue: 0.59)

    func line(_ title: String, _ name: String, _ warn: String, input: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: size * 0.75, weight: .bold, design: .monospaced)).foregroundStyle(SystemAudioLines.dim)
                .frame(width: size * 7.6, alignment: .trailing).fixedSize()
            (Text(name).fontWeight(.bold) + Text("  ▾").foregroundColor(SystemAudioLines.dim))
                .font(.system(size: size)).fixedSize(horizontal: false, vertical: true)
            if input {
                SystemAudioLevel(db: live.levelActive ? live.levelDB : nil).frame(width: size * 7, height: max(4, size * 0.35))
                    .accessibilityIdentifier("system-input-level")
                    .accessibilityValue(live.levelActive ? String(format: "%.0f dB", live.levelDB) : "not measured")
            }
            if !warn.isEmpty {
                Text(warn).font(.system(size: size * 0.85, weight: .semibold)).foregroundStyle(SystemAudioLines.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(input ? "system-input-warning" : "system-output-warning")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { SystemAudio.popMenu(input: input) }
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(input ? "Microphone of the whole Mac: \(name)" : "Speaker of the whole Mac: \(name)")
        .accessibilityIdentifier(input ? "system-input" : "system-output")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { SystemAudio.popMenu(input: input) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("MICROPHONE", live.input?.name ?? "none", live.inputWarning, input: true)
            line("SPEAKER", live.output?.name ?? "none", live.outputWarning, input: false)
            if !live.status.isEmpty || live.canUndoInput || live.canUndoOutput {
                HStack(spacing: 10) {
                    Text(live.status).font(.system(size: size * 0.75, weight: .medium)).foregroundStyle(SystemAudioLines.dim)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("system-audio-status")
                    if live.canUndoInput { Button("UNDO INPUT") { SystemAudio.undo(input: true) }.controlSize(.small)
                        .accessibilityIdentifier("system-undo-input") }
                    if live.canUndoOutput { Button("UNDO OUTPUT") { SystemAudio.undo(input: false) }.controlSize(.small)
                        .accessibilityIdentifier("system-undo-output") }
                }
                .padding(.leading, size * 7.6 + 8)
            }
        }
    }
}

struct SystemAudioLevel: View {
    let db: Float?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.15))
                if let d = db, d > -60 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d > -3 ? Color.red : d > -12 ? Color.orange : SystemAudioLines.green)
                        .frame(width: g.size.width * CGFloat(max(0, min(1, (d + 60) / 60))))
                }
            }
        }
    }
}
