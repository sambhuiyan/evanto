import AVFoundation
import Speech

// A fresh stream is created before capture starts, and on each unmute. Only
// the capture queue writes to it. The analyzer consumes the original packets
// in order, independently of the MP4 mixer's playback deadline.
final class SpeechInput: @unchecked Sendable {
    struct Packet: @unchecked Sendable {
        let pcm: AVAudioPCMBuffer
        let start: CMTime?
    }

    let id = UUID()
    let source: AudioSource
    let packets: AsyncThrowingStream<Packet, Error>
    private let continuation: AsyncThrowingStream<Packet, Error>.Continuation
    private let origin: CMTime
    private var clockOffset: CMTime?
    private var nextPTS: CMTime?
    private var nextStart = CMTime.zero
    private var ended = false
    private(set) var lastAudibleAt: ContinuousClock.Instant?

    init(source: AudioSource, origin: CMTime) {
        self.source = source
        self.origin = origin
        // Keep early audio during model preparation. A stalled analyzer reports
        // overflow explicitly instead of skipping old words in a live stream.
        (packets, continuation) = AsyncThrowingStream<Packet, Error>.makeStream(bufferingPolicy: .bufferingOldest(8_192))
    }

    func push(_ pcm: AVAudioPCMBuffer, at pts: CMTime, arrival: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        guard !ended, pcm.frameLength > 0 else { return }
        if pcm.hasAudibleSamples { lastAudibleAt = .now }
        let duration = CMTime(seconds: Double(pcm.frameLength) / pcm.format.sampleRate, preferredTimescale: 1_000_000)
        let received = CMTimeMaximum(.zero, arrival - origin - duration)
        var start: CMTime?
        if nextPTS == nil || (pts.isNumeric && abs((pts - (nextPTS ?? pts)).seconds) > 0.08) {
            if pts.isNumeric {
                if clockOffset == nil {
                    clockOffset = abs((pts - arrival).seconds) < 2 ? .zero - origin : received - pts
                }
                var mapped = pts + (clockOffset ?? .zero)
                if mapped < nextStart - CMTime(seconds: 0.08, preferredTimescale: 1000) || mapped > arrival - origin + CMTime(value: 1, timescale: 1) {
                    mapped = received
                    clockOffset = mapped - pts
                }
                start = CMTimeMaximum(nextStart, mapped)
            } else if nextPTS == nil { start = CMTimeMaximum(nextStart, received) }
        }
        nextStart = (start ?? nextStart) + duration
        nextPTS = (pts.isNumeric ? pts : (nextPTS ?? .zero)) + duration
        if case .dropped = continuation.yield(Packet(pcm: pcm, start: start)) {
            fail(EvantoError(source.rawValue + " transcription fell behind. Retry speech to resume."))
        }
    }

    func finish() { ended = true; continuation.finish() }
    func fail(_ error: Error) { ended = true; continuation.finish(throwing: error) }
}

private extension AVAudioPCMBuffer {
    // Only used to postpone a reply while more sound is arriving. Every
    // packet, including quiet speech, still goes to the transcriber.
    var hasAudibleSamples: Bool {
        let step = max(1, Int(frameLength) / 128)
        for buffer in UnsafeMutableAudioBufferListPointer(mutableAudioBufferList) {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            func exceeds<T: Comparable & SignedNumeric>(_ threshold: T) -> Bool {
                let samples = data.assumingMemoryBound(to: T.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<T>.stride
                for channel in 0..<channels {
                    for i in Swift.stride(from: channel, to: count, by: step * channels) {
                        if samples[i] > threshold || samples[i] < -threshold { return true }
                    }
                }
                return false
            }
            switch format.commonFormat {
            case .pcmFormatFloat32: if exceeds(Float(0.012)) { return true }
            case .pcmFormatFloat64: if exceeds(Double(0.012)) { return true }
            case .pcmFormatInt16: if exceeds(Int16(393)) { return true }
            case .pcmFormatInt32: if exceeds(Int32(25_769_804)) { return true }
            default: break
            }
        }
        return false
    }
}

@MainActor
enum LocalSpeech {
    private static var installations: [String: Task<Void, Error>] = [:]

    private static func prepareModel(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        if let existing = installations[locale.identifier] { return try await existing.value }
        let task = Task {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        installations[locale.identifier] = task
        defer { installations[locale.identifier] = nil }
        try await task.value
    }

    static func transcribe(_ input: SpeechInput, language: String = "en_US", onReady: @escaping () -> Void,
                           onResult: @escaping (SpeechUpdate) -> Void) async throws {
        if language == "bn_BD" {
            try await BanglaSpeech().transcribe(input, onReady: onReady, onResult: onResult)
            return
        }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw EvantoError("On-device transcription is unavailable for " + (Locale.current.localizedString(forIdentifier: language) ?? language) + ".")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await prepareModel(transcriber, locale: locale)
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EvantoError("The speech model could not select an audio format.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let results = Task {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                onResult(SpeechUpdate(result))
            }
        }
        defer { results.cancel() }
        try await withTaskCancellationHandler {
            do {
                let converter = PCMConverter()
                let sequence = input.packets.map { packet in
                    guard let pcm = converter.convert(packet.pcm, to: format) else {
                        throw EvantoError("Cannot convert " + input.source.rawValue + " audio for speech recognition.")
                    }
                    return AnalyzerInput(buffer: pcm, bufferStartTime: packet.start)
                }
                try await analyzer.start(inputSequence: sequence)
                onReady()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await results.value
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }
}
