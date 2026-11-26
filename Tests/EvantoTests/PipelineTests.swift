import XCTest
import AVFoundation
import AppKit
import PDFKit
@testable import Evanto

final class PipelineTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evanto-test-" + UUID().uuidString)
        return try Storage.directory(url)
    }

    func testNewChatsUseReloadedReferencesAndRetrieveLatePassages() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("library")
        let original = root.appendingPathComponent("example-cv.md")
        let note = String(repeating: "General project notes. ", count: 2200) + "\nThe aurora deployment won the Juniper award."
        try note.write(to: original, atomically: true, encoding: .utf8)
        _ = try ReferenceLibrary.add(original, to: lib)
        try FileManager.default.removeItem(at: original)
        for _ in 0..<2 {
            let persisted = try ReferenceLibrary.load(from: lib)
            let prompt = PromptBuilder.build(question: Question(text: "Which award did the aurora deployment win?", source: .typed),
                files: persisted, heard: "", screenshot: nil, supportsImages: false)
            XCTAssertTrue(prompt.text.contains("Juniper award"))
            XCTAssertTrue(prompt.text.contains("example-cv.md"))
            XCTAssertLessThan(prompt.text.count, note.count)
        }
        let reference = try XCTUnwrap(ReferenceLibrary.load(from: lib).first)
        try ReferenceLibrary.remove(reference, from: lib)
        XCTAssertTrue(try ReferenceLibrary.load(from: lib).isEmpty)
    }

    func testQuestionRecognitionFromSpeech() {
        XCTAssertEqual(Questions.detect(in: "Thanks. Can you explain photosynthesis"), ["Can you explain photosynthesis"])
        XCTAssertEqual(Questions.detect(in: "Tell me about your background"), ["Tell me about your background"])
        XCTAssertTrue(Questions.detect(in: "I enjoyed the meeting today.").isEmpty)
        XCTAssertEqual(Questions.detect(in: "Is 3.14 close to pi? Why?"), ["Is 3.14 close to pi?", "Why?"])
    }

    func testDevicePCMFormatsReachTheMixer() throws {
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        let mixer = AudioMixer(origin: origin)
        mixer.set(microphone: true, system: true)
        for source in [AudioSource.system, .microphone] {
            let format: AVAudioFormat
            if source == .system { format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)) }
            else { format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)) }
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 10)))
            pcm.frameLength = pcm.frameCapacity
            if let channels = pcm.floatChannelData {
                for index in 0..<Int(format.channelCount) { channels[index].initialize(repeating: 0.125, count: Int(pcm.frameLength)) }
            } else { pcm.int16ChannelData![0].initialize(repeating: 8192, count: Int(pcm.frameLength)) }
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil,
                dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                sampleCount: Int(pcm.frameLength), presentationTimeStamp: origin, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
            let audio = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(audio, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), noErr)
            XCTAssertEqual(CMSampleBufferSetDataReady(audio), noErr)
            mixer.append(try XCTUnwrap(audio.copiedPCM()), at: audio.presentationTimeStamp, source: source)
        }
        var observed = [Float]()
        mixer.drain(at: origin + CMTime(value: 205, timescale: 1000)) { pcm, _ in observed.append(pcm.floatChannelData![0][900]) }
        XCTAssertEqual(observed.count, 2)
        for value in observed { XCTAssertEqual(value, 0.375, accuracy: 0.025) }
    }

    @MainActor func testScannedCVAndWordDocumentImport() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("word")
        _ = try Storage.directory(archive)
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Juniper research</w:t></w:r></w:p></w:body></w:document>"#
        try xml.write(to: archive.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        let docx = root.appendingPathComponent("Sample.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root; zip.arguments = ["-q", docx.path, "word/document.xml"]
        try zip.run(); zip.waitUntilExit()
        let lib = root.appendingPathComponent("library")
        XCTAssertTrue(try ReferenceLibrary.add(docx, to: lib).text.contains("Juniper research"))

        let image = NSImage(size: NSSize(width: 660, height: 200), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Melissa Carter — Research Engineer" as NSString).draw(at: NSPoint(x: 20, y: 100),
                withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            return true
        }
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let scanned = root.appendingPathComponent("Scanned CV.pdf")
        XCTAssertTrue(pdf.write(to: scanned))
        XCTAssertTrue(try ReferenceLibrary.add(scanned, to: lib).text.contains("Research Engineer"))
    }

    func testEachMuteSilencesOnlyItsOwnAudioAndClearsBufferedSamples() throws {
        let mixer = AudioMixer(origin: .zero)
        let count = AudioMixer.rate / 25
        let mic = [Float](repeating: 0.20, count: count)
        let mac = [Float](repeating: 0.35, count: count)
        for (step, flags) in [(true, true), (false, true), (true, false), (false, false)].enumerated() {
            mixer.set(microphone: true, system: true)
            mic.withUnsafeBufferPointer { mixer.write($0.baseAddress!, count: count, at: step * count, source: .microphone) }
            mac.withUnsafeBufferPointer { mixer.write($0.baseAddress!, count: count, at: step * count, source: .system) }
            mixer.set(microphone: flags.0, system: flags.1)
            let expected: Float = (flags.0 ? 0.20 : 0) + (flags.1 ? 0.35 : 0)
            var observed = [Float]()
            mixer.drain(at: CMTime(value: Int64(120 + 40 * (step + 1)), timescale: 1000)) { buffer, _ in
                observed.append(buffer.floatChannelData![0][0])
            }
            XCTAssertEqual(observed.count, 1)
            XCTAssertEqual(try XCTUnwrap(observed.first), expected, accuracy: 0.0001)
        }
    }

    func testCleanRecordingWritesPlayableVideoAndMixedAudio() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Clean.mp4")
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let writer = try CleanRecording(to: url, firstFrame: pixels, at: .zero)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: 1920))
        pcm.frameLength = pcm.frameCapacity
        for i in 0..<1920 { pcm.floatChannelData![0][i] = 0.4 * sin(Float(i) * .pi / 28) }
        for i in 0..<20 {
            let when = CMTime(value: Int64(i), timescale: 25)
            writer.append(pixels, at: when)
            writer.append(pcm, at: when)
            try await Task.sleep(for: .milliseconds(8))
        }
        let saved: URL = try await withCheckedThrowingContinuation { done in
            writer.finish(at: CMTime(value: 20, timescale: 25)) { done.resume(with: $0) }
        }
        let movie = AVURLAsset(url: saved)
        let video = try await movie.loadTracks(withMediaType: .video)
        let audio = try await movie.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let duration = try await movie.load(.duration)
        XCTAssertEqual(duration.seconds, 0.8, accuracy: 0.08)
        let reader = try AVAssetReader(asset: movie)
        let track = try XCTUnwrap(audio.first)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        reader.add(decoded)
        XCTAssertTrue(reader.startReading())
        var peak: Float = 0
        while let sample = decoded.copyNextSampleBuffer(), let data = sample.dataBuffer {
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
            values.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            peak = max(peak, values.map(abs).max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 0.1)
    }

    @MainActor func testRealChatGPTSignInModelAndTextReply() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_CODEX"] == "1" else {
            throw XCTSkip("Enable EVANTO_TEST_CODEX to send a synthetic question to the signed-in account.")
        }
        let codex = CodexService()
        await codex.connect()
        defer { codex.shutdown() }
        XCTAssertTrue(codex.signedIn, codex.problem ?? codex.accountLabel)
        let model = try XCTUnwrap(codex.models.first { $0.images && $0.isDefault } ?? codex.models.first { $0.images })
        let cg = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        cg.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); cg.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let fixture = ReferenceFile(id: UUID(), name: "test-note.txt", added: Date(), text: "The project codeword is BRACKEN.", image: nil)
        let prompt = PromptBuilder.build(question: Question(text: "What are the project codeword and the solid color in the display image? Reply with only those two words.", source: .screenshot),
            files: [fixture], heard: "", screenshot: ReferenceLibrary.jpeg(try XCTUnwrap(cg.makeImage())), supportsImages: true)
        var displayed = ""
        let final = try await codex.answer(prompt, model: model) { displayed = $0 }
        XCTAssertTrue(final.lowercased().contains("bracken"), final)
        XCTAssertTrue(final.lowercased().contains("blue"), final)
        XCTAssertEqual(final, displayed)
    }

}
