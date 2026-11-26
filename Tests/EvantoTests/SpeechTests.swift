import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Evanto

final class SpeechTests: XCTestCase {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1000) }
    private func range(_ start: Double, _ end: Double) -> CMTimeRange { CMTimeRange(start: time(start), end: time(end)) }

    func testDistinctPartialSentencesRevisionsAndIndependentSpeakers() {
        var log = SpeechTranscript()
        let mac = UUID(), mic = UUID()
        func apply(_ text: String, _ from: Double, _ to: Double, _ watermark: Double,
                   _ source: AudioSource = .system, pieces: [SpeechUpdate.Piece] = []) {
            _ = log.apply(SpeechUpdate(range: range(from, to), finalizedThrough: time(watermark), text: text, pieces: pieces),
                          stream: source == .system ? mac : mic, source: source)
        }
        apply("We checked the red", 0, 4, 0, pieces: [
            .init(range: range(0, 1), text: "We "), .init(range: range(1, 2), text: "checked "),
            .init(range: range(2, 3), text: "the "), .init(range: range(3, 4), text: "red")])
        apply("the green file.", 2, 5, 0)
        apply("I am taking notes.", 2, 4, 4, .microphone)
        apply("Then we sent the report.", 6, 9, 5)
        XCTAssertEqual(log.segments.filter { $0.stream == mac }.map(\.text), ["We checked", "the green file.", "Then we sent the report."])
        XCTAssertTrue(log.segments.prefix(3).allSatisfy(\.final))
        XCTAssertTrue(log.text.contains("Microphone · I am taking notes."))
        log.finish(mac)
        XCTAssertTrue(log.segments.allSatisfy(\.final))
        XCTAssertTrue(log.text.contains("Then we sent the report."))
    }

    func testOnlyExplicitScreenshotQuestionsCanAttachLivePixels() {
        let frame = Data([91]), reference = Data([12])
        let file = ReferenceFile(id: UUID(), name: "notes.png", added: .now, text: "Saved note", image: reference)
        for source: QuestionSource in [.typed, .speech, .macAudio, .macTask, .screenshot] {
            let input = PromptBuilder.build(question: .init(text: "Help", source: source), files: [file],
                heard: "Spoken question", screenshot: frame, supportsImages: true)
            XCTAssertEqual(input.images, source == .screenshot ? [frame, reference] : [reference])
            XCTAssertEqual(input.text.contains("Image 1 is the current"), source == .screenshot)
        }
    }

    func testSpokenPromptIncludesSetupAndFollowupsAcrossSentenceFinals() throws {
        let mac = UUID(), mic = UUID()
        var log = SpeechTranscript(), cursor = SpokenReplyCursor()
        func phrase(_ text: String, _ start: Double, _ end: Double, stream: UUID) {
            _ = log.apply(.init(range: range(start, end), finalizedThrough: time(end), text: text),
                          stream: stream, source: stream == mac ? .system : .microphone)
        }
        phrase("We have two stores with different inventories.", 0, 4, stream: mac)
        phrase("Can you compare their stock?", 5.4, 8, stream: mac)
        phrase("I am checking my notes.", 7, 9, stream: mic)
        phrase("Explain how you would prioritize the next shipment.", 10.1, 17, stream: mac)
        phrase("Here is a new topic.", 21, 25, stream: mac)
        let turns = cursor.pending(in: log, stream: mac, pause: .standard)
        XCTAssertEqual(turns.map(\.text), [
            "We have two stores with different inventories. Can you compare their stock? Explain how you would prioritize the next shipment.",
            "Here is a new topic."
        ])
        let first = try XCTUnwrap(turns.first)
        XCTAssertTrue(Questions.shouldAnswer(first, from: .microphone))
        XCTAssertTrue(Questions.shouldAnswer(turns[1], from: .system))
        XCTAssertEqual(cursor.pending(in: log, stream: mac, pause: .long).count, 1)
        cursor.consume(first)
        XCTAssertEqual(cursor.pending(in: log, stream: mac, pause: .standard).map(\.text), ["Here is a new topic."])
    }

    func testExtendedVolatileResultsDoNotRepeatAlreadyAnsweredWords() throws {
        var log = SpeechTranscript(), cursor = SpokenReplyCursor()
        let stream = UUID()
        for (index, words) in ["Your background", "Your background Your experience",
                               "Your background Your experience Your goals"].enumerated() {
            _ = log.apply(.init(range: range(0, Double(index + 1)), finalizedThrough: .zero, text: words), stream: stream, source: .system)
            let turn = try XCTUnwrap(cursor.pending(in: log, stream: stream, pause: .standard).last)
            XCTAssertEqual(turn.text, ["Your background", "Your experience", "Your goals"][index])
            XCTAssertTrue(Questions.shouldAnswer(turn, from: .system))
            cursor.consume(turn)
            XCTAssertTrue(cursor.pending(in: log, stream: stream, pause: .standard).isEmpty)
        }
    }

    @MainActor private func panelText(_ state: Workspace) throws -> String {
        let frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        let host = NSHostingView(rootView: AnswerPanelView(state: state))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixels = try XCTUnwrap(bitmap.cgImage)
        return try ReferenceLibrary.recognize(pixels).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @MainActor func testPanelCanSwitchBetweenMacAudioAndScreenshot() throws {
        let state = Workspace()
        var audio = Exchange(.init(text: "A full spoken prompt.", source: .macAudio))
        audio.answer = "There are twelve notebooks."
        audio.finished = true
        let screenshot = Exchange(.init(text: "A manual screenshot.", source: .screenshot))
        state.exchanges = [audio, screenshot]
        XCTAssertEqual(state.panelExchange?.id, screenshot.id)
        state.showOtherPanelReply()
        XCTAssertEqual(state.panelExchange?.id, audio.id)
        let visible = try panelText(state)
        XCTAssertTrue(visible.localizedCaseInsensitiveContains("twelve notebooks"), visible)
        state.showOtherPanelReply()
        XCTAssertEqual(state.panelExchange?.id, screenshot.id)
    }

    private func sample(_ pcm: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
            sampleCount: Int(pcm.frameLength), presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer), noErr)
        let audio = try XCTUnwrap(buffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(audio, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(audio), noErr)
        return audio
    }

    func testStartupMuteAndUnmuteKeepPacketsInOrderWithoutMixing() async throws {
        let output = CaptureOutput(options: .init(microphone: true, macAudio: true)) { _ in }
        output.begin()
        defer { output.end() }
        let original = output.speechInputs()
        let firstMic = try XCTUnwrap(original[.microphone]), system = try XCTUnwrap(original[.system])
        func send(_ value: Float, _ source: AudioSource) throws {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: 480))
            pcm.frameLength = 480
            pcm.floatChannelData![0].initialize(repeating: value, count: 480)
            let packet = try sample(pcm, at: .zero)
            output.queue.sync { output.acceptAudio(packet, source: source) }
        }
        try send(0.1, .microphone); try send(0.2, .system)
        output.configure(.init(microphone: false, macAudio: true))
        try send(0.9, .microphone); try send(0.3, .system)
        output.configure(.init(microphone: true, macAudio: true))
        let lastMic = try XCTUnwrap(output.speechInputs()[.microphone])
        XCTAssertTrue(system === output.speechInputs()[.system])
        XCTAssertNotEqual(firstMic.id, lastMic.id)
        try send(0.4, .microphone)
        output.configure(.init(microphone: false, macAudio: false))
        for (feed, expected): (SpeechInput, [Float]) in [(firstMic,[0.1]),(system,[0.2,0.3]),(lastMic,[0.4])] {
            var values: [Float] = []
            for try await packet in feed.packets { values.append(packet.pcm.floatChannelData![0][0]) }
            XCTAssertEqual(values, expected)
        }
    }

    private func spoken(_ words: String, voice: String, in dir: URL) throws -> AVAudioPCMBuffer {
        let url = dir.appendingPathComponent(UUID().uuidString + ".aiff")
        let synth = Process()
        synth.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        synth.arguments = ["-v", voice, "-r", "165", "-o", url.path, words]
        try synth.run(); synth.waitUntilExit()
        XCTAssertEqual(synth.terminationStatus, 0)
        let file = try AVAudioFile(forReading: url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        return pcm
    }

    @MainActor func testBengaliLiveCaptionWhileAnswerIsOnScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EVANTO_TEST_BENGALI"] == "1", let path = env["EVANTO_BANGLA_FIXTURE"],
              let expected = env["EVANTO_BANGLA_KEYWORDS"], !expected.isEmpty else {
            throw XCTSkip("Provide a Bangladeshi audio fixture and its expected words to test live speech.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let keywords = expected.components(separatedBy: ",")
        let state = Workspace()
        let priorLanguage = state.speechLanguage
        defer { state.speechLanguage = priorLanguage }
        state.speechLanguage = "bn_BD"
        state.phase = .live
        state.micOn = true
        state.macOn = true
        var exchange = Exchange(.init(text: "Earlier question", source: .typed))
        exchange.answer = "Earlier answer"
        state.exchanges = [exchange]
        let output = CaptureOutput(options: .init(microphone: true, macAudio: true)) { _ in }
        output.begin()
        defer { output.end() }
        let inputs = output.speechInputs()
        XCTAssertEqual(inputs.count, 2)
        state.prepareSpeech(from: output)
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: AVAudioFrameCount(pcm.format.sampleRate * 2)))
        silence.frameLength = silence.frameCapacity
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(silence.frameLength))
        for input in inputs.values {
            input.push(pcm, at: .zero)
            input.push(silence, at: CMTime(seconds: Double(pcm.frameLength) / pcm.format.sampleRate, preferredTimescale: 48000))
        }
        func hasCaptions() -> Bool {
            inputs.keys.allSatisfy { source in
                let caption = state.caption(for: source) ?? ""
                return keywords.allSatisfy(caption.contains)
            }
        }
        for _ in 0..<240 {
            if state.speechFailed || hasCaptions() { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertFalse(state.speechFailed, state.speechStatus)
        XCTAssertTrue(hasCaptions(), state.speechContext)
        XCTAssertEqual(state.panelExchange?.answer, "Earlier answer")
        XCTAssertTrue(try panelText(state).contains("Live transcript"))
    }

    @MainActor func testMacPlaybackAutomaticallyAnswersAllThreeSentencesWhileLive() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EVANTO_TEST_SPEECH"] == "1", env["EVANTO_TEST_CODEX"] == "1" else {
            throw XCTSkip("Requires English speech assets and a signed-in Codex connection.")
        }
        let dir = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = ["The first box holds seven red notebooks.",
                     "The second box holds five blue notebooks.",
                     "I would like the total number of notebooks in both boxes."]
        let clips = try lines.map { try spoken($0, voice: "Samantha", in: dir) }
        let rate = try XCTUnwrap(clips.first).format.sampleRate
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        var samples: [Float] = []
        for (index, clip) in clips.enumerated() {
            XCTAssertEqual(clip.format.sampleRate, rate)
            let voice = try XCTUnwrap(clip.floatChannelData?[0])
            samples.append(contentsOf: UnsafeBufferPointer(start: voice, count: Int(clip.frameLength)))
            let pause = [1.0, 1.4, 3.5][index]
            samples.append(contentsOf: repeatElement(0, count: Int(rate * pause)))
        }

        // Only our generated audio enters this workspace. It has no reference
        // files, display pixels or microphone. Keep its audio stream open.
        let output = CaptureOutput(options: .init(microphone: false, macAudio: true)) { XCTFail($0.localizedDescription) }
        let state = Workspace(), defaults = UserDefaults.standard
        let savedAuto = defaults.object(forKey: "autoAnswer"), savedPause = defaults.object(forKey: "replyPauseSeconds")
        defer {
            output.end()
            state.phase = .idle
            state.newChat()
            state.codex.shutdown()
            defaults.set(savedAuto, forKey: "autoAnswer")
            defaults.set(savedPause, forKey: "replyPauseSeconds")
        }
        await state.codex.connect()
        XCTAssertTrue(state.codex.signedIn, state.codex.problem ?? "Codex sign-in unavailable")
        guard state.codex.signedIn else { return }
        state.autoAnswer = true
        state.replyPause = .standard
        state.macOn = true
        state.micOn = false
        state.phase = .live
        output.begin()
        state.prepareSpeech(from: output)
        let start = ContinuousClock.now, block = Int(rate / 10)
        var answeredBeforeThirdSentence = false
        let thirdStarts = samples.count - Int(clips[2].frameLength) - Int(rate * 3.5)
        for offset in Swift.stride(from: 0, to: samples.count, by: block) {
            let count = min(block, samples.count - offset)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = pcm.frameCapacity
            pcm.floatChannelData![0].initialize(repeating: 0, count: count)
            samples.withUnsafeBufferPointer {
                pcm.floatChannelData![1].update(from: $0.baseAddress!.advanced(by: offset), count: count)
            }
            let packet = try sample(pcm, at: CMTime(value: Int64(offset), timescale: Int32(rate)))
            output.queue.sync { output.acceptAudio(packet, source: .system) }
            if offset < thirdStarts && !state.exchanges.isEmpty { answeredBeforeThirdSentence = true }
            try await Task.sleep(until: start.advanced(by: .seconds(Double(offset + count) / rate)), clock: .continuous)
        }
        for _ in 0..<500 {
            if state.panelExchange?.finished == true || state.speechFailed { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(answeredBeforeThirdSentence)
        XCTAssertFalse(state.speechFailed, state.speechStatus)
        let reply = try XCTUnwrap(state.panelExchange, state.speechContext)
        XCTAssertTrue(state.live)
        XCTAssertEqual(state.exchanges.count, 1)
        XCTAssertEqual(reply.question.source, .macAudio)
        XCTAssertNil(reply.issue, reply.issue ?? "")
        for alternatives in [["first box", "1st box"], ["second box", "2nd box"], ["both boxes"]] {
            XCTAssertTrue(alternatives.contains(where: reply.question.text.localizedCaseInsensitiveContains), reply.question.text)
        }
        XCTAssertTrue(reply.finished)
        XCTAssertTrue(reply.answer.contains("12") || reply.answer.localizedCaseInsensitiveContains("twelve"), reply.answer)
        let visible = try panelText(state)
        for phrase in ["Mac audio", "red notebooks", "blue notebooks"] {
            XCTAssertTrue(visible.localizedCaseInsensitiveContains(phrase), visible)
        }
        XCTAssertTrue(visible.contains("12") || visible.localizedCaseInsensitiveContains("twelve"), visible)
        state.answerNow()
        XCTAssertEqual(state.panelExchange?.id, reply.id)
        XCTAssertEqual(state.exchanges.count, 1)
    }

    @MainActor func testSpeechAppearsWhileInputStaysOpenAndFinalWordsSurviveStop() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_SPEECH"] == "1" else { throw XCTSkip("Requires local English speech assets.") }
        let dir = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try spoken("We have a question about the orange notebook.", voice: "Samantha", in: dir)
        let last = try spoken("Please remember the umbrella.", voice: "Samantha", in: dir)
        let input = SpeechInput(source: .system, origin: CMClockGetTime(CMClockGetHostTimeClock()))
        var log = SpeechTranscript(), sawLive = false
        let ready = expectation(description: "Analyzer ready")
        let live = expectation(description: "Transcribed a sentence before closing input")
        let worker = Task {
            try await LocalSpeech.transcribe(input, onReady: { ready.fulfill() }) { update in
                _ = log.apply(update, stream: input.id, source: .system)
                if !sawLive, log.text.localizedCaseInsensitiveContains("notebook") { sawLive = true; live.fulfill() }
            }
        }
        defer { input.finish(); worker.cancel() }
        await fulfillment(of: [ready], timeout: 20)
        input.push(first, at: .zero)
        let length = CMTime(value: Int64(first.frameLength), timescale: Int32(first.format.sampleRate))
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(first.format.sampleRate * 2)))
        silence.frameLength = silence.frameCapacity
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(silence.frameLength))
        input.push(silence, at: length)
        await fulfillment(of: [live], timeout: 18)
        input.push(last, at: length + time(2))
        input.finish()
        try await worker.value
        XCTAssertTrue(log.text.localizedCaseInsensitiveContains("orange notebook"), log.text)
        XCTAssertTrue(log.text.localizedCaseInsensitiveContains("umbrella"), log.text)
    }

    @MainActor func testOnDeviceTranscribesBothPacketStreamsThroughTheirLastSentence() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_SPEECH"] == "1" else {
            throw XCTSkip("Enable EVANTO_TEST_SPEECH to use the installed English speech model.")
        }
        let dir = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = CaptureOutput(options: .init(microphone: true, macAudio: true)) { error in XCTFail(error.localizedDescription) }
        output.begin()
        defer { output.end() }
        let inputs = output.speechInputs()
        let fixtures: [(AudioSource,String,String)] = [
            (.system, "Samantha", "The bakery opens early in the morning. We measured the temperature before lunch. Please put the blue folder next to the window."),
            (.microphone, "Daniel", "The library closes on Friday. I counted the green notebooks on the table. Tomorrow we will visit the garden.")
        ]
        for (source, voice, words) in fixtures {
            let input = try spoken(words, voice: voice, in: dir)
            let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: source == .system ? 44_100 : 24_000, channels: 1))
            let mono = try XCTUnwrap(PCMConverter().convert(input, to: target))
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: target.sampleRate, channels: source == .system ? 2 : 1))
            for first in stride(from: 0, to: Int(mono.frameLength), by: 640) {
                let count = min(640, Int(mono.frameLength) - first)
                let packet = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                packet.frameLength = packet.frameCapacity
                // The system speaker is entirely in the right channel.
                packet.floatChannelData![0].initialize(repeating: 0, count: count)
                let channel = source == .system ? 1 : 0
                packet.floatChannelData![channel].update(from: mono.floatChannelData![0].advanced(by: first), count: count)
                let pts = CMTime(value: Int64(first), timescale: Int32(target.sampleRate)) + time(source == .microphone ? 900000 : 21)
                let audio = try sample(packet, at: pts)
                output.queue.sync { output.acceptAudio(audio, source: source) }
            }
        }
        // Both streams already contain all their packets when the analyzers
        // open. Closing them with no added silence must finalize the last words.
        output.configure(.init(microphone: false, macAudio: false))
        var log = SpeechTranscript()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (source, input) in inputs {
                group.addTask { @MainActor in
                    try await LocalSpeech.transcribe(input, onReady: {}) { update in _ = log.apply(update, stream: input.id, source: source) }
                }
            }
            try await group.waitForAll()
        }
        let mac = log.segments.filter { $0.source == .system }.map(\.text).joined(separator: " ").lowercased()
        let mic = log.segments.filter { $0.source == .microphone }.map(\.text).joined(separator: " ").lowercased()
        for word in ["bakery","morning","temperature","lunch","blue","window"] { XCTAssertTrue(mac.contains(word), mac) }
        for word in ["library","friday","green","table","tomorrow","garden"] { XCTAssertTrue(mic.contains(word), mic) }
        XCTAssertFalse(mac.contains("notebook")); XCTAssertFalse(mic.contains("bakery"))
    }
}
