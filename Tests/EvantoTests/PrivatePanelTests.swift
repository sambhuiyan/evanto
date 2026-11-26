import AppKit
import AVFoundation
import Vision
import XCTest
@testable import Evanto

final class PrivatePanelTests: XCTestCase {
    @MainActor func testIndependentRecorderSeesThePageThroughTheProductionPanel() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_CAPTURE"] == "1", CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Requires an already-authorized ScreenCaptureKit test runner.")
        }
        _ = NSApplication.shared
        let dir = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: dir) }
        let screen = try XCTUnwrap(NSScreen.screens.first).frame
        let rect = NSRect(x: screen.midX - 215, y: screen.midY - 100, width: 430, height: 200)
        let back = NSWindow(contentRect: rect.insetBy(dx: -10, dy: -10), styleMask: .borderless, backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.level = .init(rawValue: -93)
        back.backgroundColor = .white
        let label = NSTextField(labelWithString: "SHARED WORK PAGE")
        label.textColor = .black
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.frame = NSRect(x: 55, y: 65, width: 360, height: 70)
        back.contentView?.addSubview(label)
        back.orderFrontRegardless()
        defer { back.orderOut(nil) }

        let state = Workspace()
        state.phase = .live
        var answer = Exchange(.init(text: "Synthetic interview question", source: .macAudio))
        answer.answer = "PRIVATE SAFFRON ANSWER"
        answer.finished = true
        state.exchanges = [answer]
        let panel = AnswerPanel(state: state, presentation: .protectedVideo)
        let control = AnswerPanel(state: state, presentation: .protectedVideo)
        for window in [panel, control] { window.setFrame(rect, display: false); window.level = .init(rawValue: -92) }
        func media(_ window: NSWindow) throws -> AVSampleBufferDisplayLayer {
            try XCTUnwrap((window.contentView as? ProtectedHostingView<AnswerPanelView>)?.video)
        }
        let secure = try media(panel), plain = try media(control)
        XCTAssertTrue(secure.preventsCapture)
        // The control uses exactly the same panel and rendered bytes. Only the
        // control's synthetic pixels are made shareable, before it is displayed.
        plain.preventsCapture = false
        control.present()
        panel.present()
        defer { panel.orderOut(nil); control.orderOut(nil) }
        for _ in 0..<60 {
            if secure.isReadyForDisplay && plain.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(secure.isReadyForDisplay)
        XCTAssertFalse(secure.isOutputObscuredDueToInsufficientExternalProtection)
        XCTAssertTrue(plain.isReadyForDisplay)

        // The recorder runs in another process. It explicitly INCLUDES the
        // protected panel. Other desktop windows are outside this fixture.
        let source = #"""
        import AppKit
        import AVFoundation
        import ScreenCaptureKit
        final class Sink: NSObject, SCStreamOutput, SCRecordingOutputDelegate {
            let lock = NSLock()
            var live: CGImage?
            var finished = false
            var failure: String?
            let ci = CIContext(options: [.cacheIntermediates: false])
            func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
                guard type == .screen, let pixels = buffer.imageBuffer else { return }
                let raw = CIImage(cvPixelBuffer: pixels)
                guard let frame = ci.createCGImage(raw, from: raw.extent) else { return }
                lock.withLock { live = frame }
            }
            func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { lock.withLock { finished = true } }
            func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
                lock.withLock { failure = error.localizedDescription }
            }
        }
        enum Issue: Error { case windowsMissing, noLiveFrame, noMovie }
        func run() async throws {
            let args = CommandLine.arguments
            let root = URL(fileURLWithPath: args[4])
            func save(_ image: CGImage, as name: String) throws {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
            }
            let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            func window(_ argument: String) -> SCWindow? { all.windows.first { $0.windowID == UInt32(argument) } }
            guard let back = window(args[1]), let panel = window(args[2]), let control = window(args[3]),
                  let display = all.displays.first(where: { $0.frame.contains(panel.frame.origin) }),
                  panel.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else { throw Issue.windowsMissing }
            let config = SCStreamConfiguration()
            config.sourceRect = panel.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).insetBy(dx: -3, dy: -3)
            config.width = Int(config.sourceRect.width) * 2; config.height = Int(config.sourceRect.height) * 2
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
            let recorded = SCContentFilter(display: display, including: [back, panel])
            for (name, filter) in [("back", SCContentFilter(display: display, including: [back])),
                ("control", SCContentFilter(display: display, including: [back, control])), ("protected", recorded)] {
                try await save(SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), as: name + ".png")
            }
            let single = SCStreamConfiguration()
            single.width = 860; single.height = 400; single.showsCursor = false; single.ignoreShadowsSingleWindow = true
            try await save(SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: panel),
                configuration: single), as: "window.png")
            let sink = Sink()
            let stream = SCStream(filter: recorded, configuration: config, delegate: nil)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "fixture.capture"))
            let movie = SCRecordingOutputConfiguration()
            movie.outputURL = root.appendingPathComponent("external.mp4")
            movie.outputFileType = .mp4
            let writer = SCRecordingOutput(configuration: movie, delegate: sink)
            try stream.addRecordingOutput(writer)
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(1.2))
            try await stream.updateContentFilter(SCContentFilter(display: display, including: [back]))
            try await Task.sleep(for: .milliseconds(250))
            sink.lock.withLock { sink.live = nil }
            try await stream.updateContentFilter(recorded)
            try await Task.sleep(for: .milliseconds(500))
            try await stream.stopCapture()
            for _ in 0..<100 {
                if sink.lock.withLock({ sink.finished || sink.failure != nil }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let live = sink.lock.withLock({ sink.live }) else { throw Issue.noLiveFrame }
            try save(live, as: "live.png")
            guard sink.lock.withLock({ sink.finished }) else { throw Issue.noMovie }
        }
        try await run()
        """#
        let script = dir.appendingPathComponent("Recorder.swift")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let recorder = Process()
        recorder.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        recorder.arguments = [script.path, String(back.windowNumber), String(panel.windowNumber), String(control.windowNumber), dir.path]
        try recorder.run()
        defer { if recorder.isRunning { recorder.terminate() } }
        for _ in 0..<300 {
            if !recorder.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(recorder.isRunning)
        guard !recorder.isRunning else { return }
        XCTAssertEqual(recorder.terminationStatus, 0)
        func image(_ name: String) throws -> CGImage {
            try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(name + ".png")))?.cgImage)
        }
        let reference = try image("back"), protected = try image("protected")
        let visible = try ReferenceLibrary.recognize(image("control"))
        XCTAssertTrue(visible.localizedCaseInsensitiveContains("PRIVATE SAFFRON ANSWER"), visible)
        XCTAssertTrue(visible.localizedCaseInsensitiveContains("Send screenshot"), visible)
        for frame in [protected, try image("live")] {
            XCTAssertEqual(try rgba(frame), try rgba(reference), "The panel left pixels over the shared page")
        }
        let isolated = try rgba(image("window"))
        XCTAssertFalse(stride(from: 3, to: isolated.count, by: 4).contains { isolated[$0] != 0 }, "The selected panel drew visible pixels")
        let movie = AVAssetImageGenerator(asset: AVURLAsset(url: dir.appendingPathComponent("external.mp4")))
        let saved = try await movie.image(at: CMTime(value: 1, timescale: 3)).image
        let recordedText = try ReferenceLibrary.recognize(saved)
        XCTAssertTrue(recordedText.localizedCaseInsensitiveContains("SHARED WORK PAGE"), recordedText)
        XCTAssertFalse(recordedText.localizedCaseInsensitiveContains("SAFFRON"), recordedText)

        func systemScreenshot(of window: NSWindow, name: String) async throws -> CGImage? {
            let file = dir.appendingPathComponent(name + ".png"), tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            tool.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
            tool.standardError = FileHandle.nullDevice
            try tool.run()
            for _ in 0..<100 {
                if !tool.isRunning { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            if tool.isRunning { tool.terminate(); throw EvantoError("System screenshot timed out.") }
            guard tool.terminationStatus == 0 else { return nil }
            return try image(name)
        }
        let ordinaryShot = try await systemScreenshot(of: control, name: "system-control")
        let ordinaryWords = try ReferenceLibrary.recognize(XCTUnwrap(ordinaryShot))
        XCTAssertTrue(ordinaryWords.localizedCaseInsensitiveContains("PRIVATE SAFFRON ANSWER"), ordinaryWords)
        if let privateShot = try await systemScreenshot(of: panel, name: "system-private") {
            let pixels = try rgba(privateShot)
            XCTAssertFalse(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 })
        }

        // Locate the actual button on the visible control frame. Deliver the
        // click to the protected window only, without moving the user's mouse.
        let words = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: image("control")).perform([words])
        let bounds = try XCTUnwrap(words.results?.compactMap { observation -> CGRect? in
            guard let line = observation.topCandidates(1).first,
                  let range = line.string.range(of: "Send screenshot", options: .caseInsensitive) else { return nil }
            return try? line.boundingBox(for: range)?.boundingBox
        }.first)
        let location = NSPoint(x: bounds.midX * (rect.width + 6) - 3, y: bounds.midY * (rect.height + 6) - 3)
        let host = try XCTUnwrap(panel.contentView)
        XCTAssertNotNil(host.hitTest(host.convert(location, from: nil)))
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let up = try event(.leftMouseUp)
        NSApp.postEvent(up, atStart: false)
        panel.sendEvent(try event(.leftMouseDown))
        panel.sendEvent(up)
        for _ in 0..<20 where state.panelExchange?.question.source != .screenshot { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(state.panelExchange?.question.source, .screenshot)
        // The fixture is signed out. The actual button must have run its error
        // path, with no screenshot or network request from the fixture.
        XCTAssertTrue(state.panelExchange?.issue?.contains("Sign in") == true)
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let width = 200, height = 100, stride = width * 4
        var data = Data(count: stride * height)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }
}
