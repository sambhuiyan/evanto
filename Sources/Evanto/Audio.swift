import AVFoundation
import CoreMedia

enum AudioSource: String, CaseIterable {
    case microphone = "Microphone"
    case system = "Mac audio"
}

extension CMSampleBuffer {
    func copiedPCM() -> AVAudioPCMBuffer? {
        guard numSamples > 0, let description = formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(numSamples),
            into: pcm.mutableAudioBufferList) == noErr else { return nil }
        return pcm
    }
}

final class PCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        lock.lock()
        defer { lock.unlock() }
        if converter?.inputFormat != input.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.primeMethod = .none
            converter?.downmix = input.format.channelCount > format.channelCount
        }
        guard let converter else { return nil }
        let capacity = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        return status != .error && result.frameLength > 0 ? result : nil
    }
}

// All accesses to this mixer run on the capture queue. The two devices can
// deliver different packet sizes, sample rates and timestamps.
final class AudioMixer {
    static let rate = 48_000
    static let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
    private let capacity = rate * 2
    private var microphone = [Float](repeating: 0, count: rate * 2)
    private var system = [Float](repeating: 0, count: rate * 2)
    private var micConverter = PCMConverter()
    private var systemConverter = PCMConverter()
    private var micOn = false, systemOn = false
    private let origin: CMTime
    private var next = 0

    init(origin: CMTime) { self.origin = origin }

    func set(microphone mic: Bool, system mac: Bool) {
        if mic != micOn { microphone = [Float](repeating: 0, count: capacity); micConverter = PCMConverter() }
        if mac != systemOn { system = [Float](repeating: 0, count: capacity); systemConverter = PCMConverter() }
        micOn = mic
        systemOn = mac
    }

    func append(_ pcm: AVAudioPCMBuffer, at timestamp: CMTime, source: AudioSource) {
        guard source == .microphone ? micOn : systemOn else { return }
        let converter = source == .microphone ? micConverter : systemConverter
        guard let mono = converter.convert(pcm, to: Self.format), let values = mono.floatChannelData?[0] else { return }
        let length = Int(mono.frameLength)
        let now = frame(at: CMClockGetTime(CMClockGetHostTimeClock()))
        var start = frame(at: timestamp)
        // Some audio devices use their own clock epoch.
        if abs(Double(start) - Double(now)) > Double(Self.rate) { start = now - length }
        write(values, count: length, at: start, source: source)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int, at start: Int, source: AudioSource) {
        guard source == .microphone ? micOn : systemOn else { return }
        let first = max(0, next - start), end = min(count, next + capacity - start)
        guard first < end else { return }
        for i in first..<end {
            let slot = (start + i) % capacity
            if source == .microphone { microphone[slot] = samples[i] } else { system[slot] = samples[i] }
        }
    }

    private func frame(at time: CMTime) -> Int {
        guard time.isNumeric else { return -Self.rate * 2 }
        return Int(CMTimeConvertScale(time - origin, timescale: Int32(Self.rate), method: .roundTowardZero).value)
    }

    func drain(at time: CMTime, _ consume: (AVAudioPCMBuffer, CMTime) -> Void) {
        let until = frame(at: time) - Self.rate * 12 / 100
        let block = Self.rate / 25
        if until - next > capacity {
            next = until - block
            microphone = [Float](repeating: 0, count: capacity)
            system = [Float](repeating: 0, count: capacity)
        }
        while until - next >= block {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(block)),
                  let samples = pcm.floatChannelData?[0] else { return }
            pcm.frameLength = pcm.frameCapacity
            for i in 0..<block {
                let slot = (next + i) % capacity
                samples[i] = max(-1, min(1, microphone[slot] + system[slot]))
                microphone[slot] = 0
                system[slot] = 0
            }
            consume(pcm, origin + CMTime(value: Int64(next), timescale: Int32(Self.rate)))
            next += block
        }
    }
}
