import AVFoundation
import whisper

// One loaded Bengali model serves both inputs. Each request supplies its
// own audio and disables decoder history so speakers cannot bleed together.
private actor BanglaDecoder {
    static let shared = BanglaDecoder()
    private var context: OpaquePointer?

    func prepare() throws {
        guard context == nil else { return }
        let name = "ggml-bengaliai-whisper-medium-q5_0.bin"
        var model = Bundle.main.resourceURL?.appendingPathComponent(name)
        #if DEBUG
        if model.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            model = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/bangla/" + name)
        }
        #endif
        guard let model, FileManager.default.fileExists(atPath: model.path) else {
            throw EvantoError("The Bangla speech model is missing from Evanto.")
        }
        context = whisper_init_from_file_with_params(model.path, whisper_context_default_params())
        guard context != nil else { throw EvantoError("Could not load the Bangla speech model.") }
    }

    func decode(_ audio: [Float]) throws -> String {
        try Task.checkCancellation()
        try prepare()
        guard let context else { throw EvantoError("Bangla transcription is unavailable.") }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.no_context = true
        params.translate = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        let result = "bn".withCString { language in
            params.language = language
            return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
        guard result == 0 else { throw EvantoError("Bangla speech recognition failed. Choose Retry speech.") }
        return (0..<whisper_full_n_segments(context)).compactMap { index in
            whisper_full_get_segment_text(context, index).map { String(cString: $0) }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class BanglaSpeech {
    private struct Revision {
        let samples: [Float]
        let start: Int64
        let final: Bool
    }
    private var pending: [Revision] = []
    private var worker: Task<Void, Never>?
    private var samples: [Float] = []
    private var nextSample: Int64 = 0
    private var start: Int64 = 0
    private var quiet = 0
    private var lastPartial = 0
    private var failure: Error?
    private let rate: Int32 = 16_000

    func transcribe(_ input: SpeechInput, onReady: @escaping () -> Void,
                    onResult: @escaping (SpeechUpdate) -> Void) async throws {
        try await BanglaDecoder.shared.prepare()
        try Task.checkCancellation()
        let converter = PCMConverter()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        defer { worker?.cancel() }
        onReady()
        for try await packet in input.packets {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard let pcm = converter.convert(packet.pcm, to: format), let data = pcm.floatChannelData?[0] else {
                throw EvantoError("Could not convert audio for Bangla captions.")
            }
            if let time = packet.start {
                let mapped = CMTimeConvertScale(time, timescale: rate, method: .default).value
                if abs(mapped - nextSample) > 1_600 { schedule(final: true, onResult: onResult) }
                nextSample = mapped
            }
            for offset in stride(from: 0, to: Int(pcm.frameLength), by: 320) {
                let frame = UnsafeBufferPointer(start: data.advanced(by: offset), count: min(320, Int(pcm.frameLength) - offset))
                let audible = frame.reduce(Float(0)) { $0 + $1 * $1 } > Float(frame.count) * 0.000009
                if !samples.isEmpty || audible {
                    if samples.isEmpty { start = nextSample }
                    samples.append(contentsOf: frame)
                    quiet = audible ? 0 : quiet + frame.count
                    if quiet >= 10_400 || samples.count >= 384_000 || (samples.count > 192_000 && quiet > 3_200) {
                        schedule(final: true, onResult: onResult)
                    } else if samples.count - lastPartial >= 32_000 {
                        schedule(final: false, onResult: onResult)
                    }
                }
                nextSample += Int64(frame.count)
            }
        }
        schedule(final: true, onResult: onResult)
        await worker?.value
        if let failure { throw failure }
    }

    private func schedule(final: Bool, onResult: @escaping (SpeechUpdate) -> Void) {
        guard !samples.isEmpty, failure == nil else { return }
        if pending.last?.start == start { pending.removeLast() }
        let queuedSamples = pending.reduce(samples.count) { $0 + $1.samples.count }
        guard queuedSamples <= Int(rate) * 90 else {
            pending.removeAll()
            failure = EvantoError("Bangla transcription fell behind. Retry speech to resume.")
            return
        }
        pending.append(Revision(samples: samples, start: start, final: final))
        lastPartial = samples.count
        if final { samples = []; lastPartial = 0; quiet = 0 }
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            do {
                while !pending.isEmpty {
                    let revision = pending.removeFirst()
                    let text = try await BanglaDecoder.shared.decode(revision.samples)
                    try Task.checkCancellation()
                    let range = CMTimeRange(start: CMTime(value: revision.start, timescale: rate),
                                            duration: CMTime(value: Int64(revision.samples.count), timescale: rate))
                    onResult(SpeechUpdate(range: range, finalizedThrough: revision.final ? range.end : .invalid, text: text))
                }
            } catch { failure = error; pending.removeAll() }
        }
    }
}
