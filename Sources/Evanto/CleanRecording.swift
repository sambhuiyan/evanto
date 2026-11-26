import AVFoundation
import CoreMedia

// The writer receives only filtered display frames and the post-mute audio mix.
// Keeping it separate from SCStreamConfiguration lets the user mute mid-recording.
final class CleanRecording {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let audioDescription: CMAudioFormatDescription
    private let start: CMTime
    private let target: URL
    private let staging: URL
    private var lastVideo = CMTime.invalid
    private var lastPixel: CVPixelBuffer?
    private var failure: Error?

    init(to target: URL, firstFrame: CVPixelBuffer, at time: CMTime) throws {
        self.target = target
        staging = target.deletingLastPathComponent().appendingPathComponent(".evanto-\(UUID().uuidString).mp4")
        start = time
        writer = try AVAssetWriter(url: staging, fileType: .mp4)
        let width = CVPixelBufferGetWidth(firstFrame), height = CVPixelBufferGetHeight(firstFrame)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000, AVVideoExpectedSourceFrameRateKey: 24]])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioMixer.rate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        audioDescription = AudioMixer.format.formatDescription
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video), writer.canAdd(audio) else { throw EvantoError("This Mac could not create the recording tracks.") }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? EvantoError("The recording file could not be opened.") }
        writer.startSession(atSourceTime: time)
        append(firstFrame, at: time)
    }

    func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard time >= start, !lastVideo.isValid || time > lastVideo, writer.status == .writing else { return }
        lastPixel = buffer
        guard video.isReadyForMoreMediaData else { return }
        if pixels.append(buffer, withPresentationTime: time) { lastVideo = time }
        else { failure = writer.error ?? EvantoError("A screen frame could not be recorded.") }
    }

    func append(_ pcm: AVAudioPCMBuffer, at time: CMTime) {
        guard time >= start, writer.status == .writing, audio.isReadyForMoreMediaData else { return }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: audioDescription,
            sampleCount: Int(pcm.frameLength), presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr, let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
            CMSampleBufferSetDataReady(sample) == noErr else {
                failure = EvantoError("An audio sample could not be recorded.")
                return
        }
        if !audio.append(sample) { failure = writer.error ?? EvantoError("The recording could not accept audio.") }
    }

    func finish(at time: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        if let lastPixel { append(lastPixel, at: time) }
        self.lastPixel = nil
        if writer.status == .writing {
            writer.endSession(atSourceTime: time)
            audio.markAsFinished()
            video.markAsFinished()
        }
        let deliver = { [self] in
            do {
                if let failure { throw failure }
                guard writer.status == .completed else { throw writer.error ?? EvantoError("The recording did not finish.") }
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                } else { try FileManager.default.moveItem(at: staging, to: target) }
                completion(.success(target))
            } catch {
                try? FileManager.default.removeItem(at: staging)
                completion(.failure(error))
            }
        }
        if writer.status == .writing { writer.finishWriting(completionHandler: deliver) }
        else { deliver() }
    }
}
