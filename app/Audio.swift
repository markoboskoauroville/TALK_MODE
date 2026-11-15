// Audio.swift: the ears of Talk Mode. The Mac's chosen input (never a virtual device, never the camera's audio path),
// 16 kHz mono, a voice-activity detector that cuts an utterance after a pause, and the WAV that goes to MANTRA_VOICE /hear.
import AVFoundation
import CoreAudio

struct InputDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum Devices {
    /// names that belong to a camera or a phone camera: never listened to (the Second Take on the Sony body stays untouched)
    static let cameraWords = ["sony", "camera", "webcam", "iriun", "ilce", "zv-", "alpha", "fx3", "fx30", "a7"]

    static func isCamera(_ name: String) -> Bool {
        let n = name.lowercased()
        return cameraWords.contains { n.contains($0) }
    }

    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = addr(sel)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v
    }

    static func inputChannels(_ id: AudioObjectID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func isVirtual(_ id: AudioObjectID) -> Bool {
        let t = uint(id, kAudioDevicePropertyTransportType)
        return t == kAudioDeviceTransportTypeVirtual || t == kAudioDeviceTransportTypeAggregate
            || t == kAudioDeviceTransportTypeAutoAggregate || t == 0
    }

    /// real microphones only: no BlackHole, NDI, Zoom, aggregate, and nothing that belongs to a camera
    static func inputs() -> [InputDevice] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, !isVirtual(id) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Input \(id)"
            guard !isCamera(name) else { return nil }
            return InputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: name)
        }
    }

    static func defaultInputID() -> AudioDeviceID {
        uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    /// the saved choice; else the Mac's default input when it is a real microphone; else the MacBook's own microphone
    static func pick(savedUID: String?) -> InputDevice? {
        let all = inputs()
        if let s = savedUID, let d = all.first(where: { $0.uid == s }) { return d }
        let def = defaultInputID()
        if let d = all.first(where: { $0.id == def }) { return d }
        return all.first(where: { $0.name.lowercased().contains("macbook") }) ?? all.first
    }
}

/// The microphone, converted to 16 kHz mono Float32. A fresh AVAudioEngine for every start (a device change is a restart).
final class Ears {
    static let rate = 16000.0
    private var engine: AVAudioEngine?
    var onSamples: (([Float]) -> Void)?
    private(set) var running = false

    func start(device: InputDevice?) throws {
        stop()
        let e = AVAudioEngine()
        let input = e.inputNode
        if let dev = device, let au = input.audioUnit {
            var d = dev.id
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { NSLog("[Ears] could not select %@ (%d)", dev.name, st) }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Ears", code: 1, userInfo: [NSLocalizedDescriptionKey: "the microphone gives no sound (permission?)"])
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Ears.rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: fmt, to: target) else {
            throw NSError(domain: "Ears", code: 2, userInfo: [NSLocalizedDescriptionKey: "no converter for \(fmt)"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * Ears.rate / fmt.sampleRate + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            guard err == nil, out.frameLength > 0, let p = out.floatChannelData?[0] else { return }
            self.onSamples?(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))))
        }
        e.prepare()
        try e.start()
        engine = e
        running = true
    }

    func stop() {
        if let e = engine { e.inputNode.removeTap(onBus: 0); e.stop() }
        engine = nil
        running = false
    }
}

/// Voice activity: 30 ms frames, an adaptive noise floor, an utterance starts after 90 ms of voice (with 300 ms before it
/// kept) and ends after `pause` seconds of silence; one shorter than `minLength` seconds of voice span is a noise.
final class VAD {
    let frame = 480                       // 30 ms at 16 kHz
    var pause = 1.3
    var minLength = 0.6
    var maxLength = 60.0
    private(set) var floorDB: Float = -60
    private(set) var levelDB: Float = -90
    private var pending: [Float] = []
    private var pre: [[Float]] = []
    private var inUtt = false
    private var utt: [Float] = []
    private var startRun = 0
    private var silent = 0
    private var framesIn = 0
    private var lastVoice = 0
    var onStart: (() -> Void)?
    var onUtterance: (([Float], Double) -> Void)?      // samples, voice span in seconds
    var onNoise: ((Double) -> Void)?
    var speaking: Bool { inUtt }

    func reset() { pending = []; pre = []; inUtt = false; utt = []; startRun = 0; silent = 0; framesIn = 0; lastVoice = 0 }

    func feed(_ s: [Float]) {
        pending.append(contentsOf: s)
        var i = 0
        while pending.count - i >= frame { step(Array(pending[i..<(i + frame)])); i += frame }
        if i > 0 { pending.removeFirst(i) }
    }

    private func step(_ f: [Float]) {
        var sum: Float = 0
        for x in f { sum += x * x }
        let db = 20 * log10(max(sqrt(sum / Float(f.count)), 1e-7))
        levelDB = db
        let threshold = max(floorDB + 12, -50)
        let voice = db > threshold
        if !voice {                                   // the floor follows the room, quickly down, slowly up
            floorDB += (db - floorDB) * (db < floorDB ? 0.2 : 0.01)
            floorDB = min(floorDB, -30)
        }
        let secs = Double(frame) / Ears.rate
        if !inUtt {
            pre.append(f); if pre.count > 10 { pre.removeFirst() }
            startRun = voice ? startRun + 1 : 0
            if startRun >= 3 {
                inUtt = true
                utt = pre.flatMap { $0 }
                framesIn = pre.count; lastVoice = framesIn; silent = 0
                onStart?()
            }
            return
        }
        utt.append(contentsOf: f); framesIn += 1
        if voice { silent = 0; lastVoice = framesIn } else { silent += 1 }
        if Double(silent) * secs >= pause || Double(framesIn) * secs >= maxLength { finish(secs) }
    }

    /// SEND NOW (v6): the utterance ends here, without waiting for the pause; anything over 0.2 s of voice counts
    func forceEnd() { if inUtt { finish(Double(frame) / Ears.rate, forced: true) } }

    private func finish(_ secs: Double, forced: Bool = false) {
        inUtt = false
        let span = Double(lastVoice - min(lastVoice, 10)) * secs     // from the voice start (after the pre-roll) to the last voice
        let keep = min(utt.count, (lastVoice + 10) * frame)          // 300 ms of silence after the last voice
        let samples = Array(utt.prefix(keep))
        utt = []; pre = []; startRun = 0
        if span >= (forced ? 0.2 : minLength) { onUtterance?(samples, span) } else { onNoise?(span) }
    }
}

enum WAV {
    /// 16-bit PCM mono at 16 kHz, what /hear takes as audio/wav
    static func data(_ s: [Float], rate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(s.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        var pcm = [Int16](repeating: 0, count: s.count)
        for (i, x) in s.enumerated() { pcm[i] = Int16(max(-1, min(1, x)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// any audio file AVAudioFile reads, as 16 kHz mono (the debug path: --test-wav)
    static func load(_ path: String) throws -> [Float] {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let src = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        try f.read(into: buf)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Ears.rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(f.length) * Ears.rate / src.sampleRate + 1024))
        else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return buf
        }
        if let err { throw err }
        guard let p = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }
}
