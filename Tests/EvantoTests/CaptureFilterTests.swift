import AppKit
import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import Evanto

final class CaptureFilterTests: XCTestCase {
    // The two test windows sit behind ordinary windows. Only a small rectangle
    // is sampled, with every unrelated application excluded from the stream.
    @MainActor func testFilteredStreamShowsQuestionBehindExcludedWindow() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_CAPTURE"] == "1",
              CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("This test uses an already-authorized ScreenCaptureKit runner and two synthetic windows.")
        }
        let directory = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("Fixture.swift")
        let ready = directory.appendingPathComponent("ready")
        let pageChange = directory.appendingPathComponent("page")
        let source = #"""
        import AppKit
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screen = NSScreen.screens[0].frame
        let rect = NSRect(x: screen.midX - 185, y: screen.midY - 100, width: 370, height: 200)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Evanto synthetic shared surface"
        window.level = NSWindow.Level(rawValue: -90)
        window.backgroundColor = .white
        let label = NSTextField(labelWithString: "What is seven plus nine?")
        label.font = .systemFont(ofSize: 25, weight: .semibold)
        label.textColor = .black
        label.frame = NSRect(x: 20, y: 27, width: 335, height: 40)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        try String(window.windowNumber).write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        let page = URL(fileURLWithPath: CommandLine.arguments[2])
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let text = try? String(contentsOf: page, encoding: .utf8), text != label.stringValue {
                label.stringValue = text
                window.displayIfNeeded()
            }
        }
        withExtendedLifetime(window) { app.run() }
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        helper.arguments = [script.path, ready.path, pageChange.path]
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        var windowID: UInt32?
        for _ in 0..<120 {
            if let value = try? String(contentsOf: ready, encoding: .utf8), let id = UInt32(value) { windowID = id; break }
            try await Task.sleep(for: .milliseconds(125))
        }
        let underID = try XCTUnwrap(windowID)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let frame = try XCTUnwrap(NSScreen.screens.first).frame
        let rect = NSRect(x: frame.midX - 185, y: frame.midY - 100, width: 370, height: 200)
        let panelState = Workspace()
        var answer = Exchange(.init(text: "Fixture question", source: .macAudio))
        answer.answer = "PRIVATE ANSWER PANEL"
        answer.finished = true
        panelState.exchanges = [answer]
        let overlay = AnswerPanel(state: panelState, presentation: .native)
        XCTAssertEqual(overlay.sharingType, .none)
        // Simulate a recorder that ignores the legacy window flag. The
        // positive control is the real native answer panel with synthetic text.
        overlay.sharingType = .readOnly
        overlay.setFrame(rect, display: false)
        overlay.level = NSWindow.Level(rawValue: -89)
        overlay.present()
        defer { overlay.orderOut(nil) }
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let under = try XCTUnwrap(available.windows.first { $0.windowID == underID })
        let above = try XCTUnwrap(available.windows.first { $0.windowID == UInt32(overlay.windowNumber) })
        let owner = try XCTUnwrap(under.owningApplication)
        let excludedOwner = try XCTUnwrap(above.owningApplication)
        XCTAssertNotEqual(owner.processID, excludedOwner.processID)
        let display = try XCTUnwrap(available.displays.first { $0.frame.contains(under.frame.origin) })
        let config = SCStreamConfiguration()
        config.sourceRect = under.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).insetBy(dx: 3, dy: 3)
        config.width = Int(config.sourceRect.width * 2)
        config.height = Int(config.sourceRect.height * 2)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        let both = SCContentFilter(display: display, including: [under, above])
        let covered = try await SCScreenshotManager.captureImage(contentFilter: both, configuration: config)
        let coveredWords = try ReferenceLibrary.recognize(covered)
        XCTAssertTrue(coveredWords.localizedCaseInsensitiveContains("PRIVATE ANSWER PANEL"), coveredWords)

        let excluded = available.applications.filter { $0.processID != owner.processID }
        XCTAssertTrue(excluded.contains { $0.processID == excludedOwner.processID })
        let filtered = LiveCapture.cleanFilter(display: display, excluding: excluded)
        let output = CaptureOutput(options: .init(microphone: false, macAudio: false), refreshImage: {
            try await SCScreenshotManager.captureImage(contentFilter: filtered, configuration: config)
        }, onStop: { error in XCTFail(error.localizedDescription) })
        let stream = SCStream(filter: filtered, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        output.begin()
        defer { output.end() }
        try await stream.startCapture()
        for _ in 0..<80 {
            if output.screenshotForSend() != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        var localCloses = 0
        var displayStatus: ShareDisplayStatus = .preparing
        let feed = CleanShareSession(output: output, size: CGSize(width: config.width, height: config.height),
                                    onDisplayStatus: { displayStatus = $0 }) { localCloses += 1 }
        defer { feed.stop() }
        for _ in 0..<40 where displayStatus == .preparing {
            // XCTest does not run NSApplication.run() to deliver display changes.
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(displayStatus, .ready)
        let virtualID = try XCTUnwrap(feed.displayID)
        guard virtualID != CGMainDisplayID(), CGDisplayIsBuiltin(virtualID) == 0, CGDisplayIsInMirrorSet(virtualID) == 0 else {
            return XCTFail("The test receiver must target an independent software display.")
        }
        let id = UInt32(feed.source.windowNumber)
        let windows = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let share = try XCTUnwrap(windows.windows.first { $0.windowID == id })
        XCTAssertEqual(share.title, "Shared Screen")
        XCTAssertEqual(share.windowLayer, 0)
        XCTAssertFalse(feed.source.styleMask.contains(.titled))
        XCTAssertFalse(feed.previewWindow.isVisible)
        let picture = feed.source.convertToScreen(feed.source.picture.video.frame)
        XCTAssertGreaterThan(picture.width, 100)
        XCTAssertFalse(NSScreen.workDisplays.contains { $0.frame.intersection(picture).width > 0 })

        // The receiver stays attached to one window, as in a meeting. It can
        // only observe synthetic frames delivered on this stream.
        let recapture = SCContentFilter(desktopIndependentWindow: share)
        let windowConfig = SCStreamConfiguration()
        windowConfig.width = 740; windowConfig.height = 400; windowConfig.showsCursor = false
        let receiver = CaptureOutput(options: .init(microphone: false, macAudio: false)) { error in XCTFail(error.localizedDescription) }
        let meeting = SCStream(filter: recapture, configuration: windowConfig, delegate: receiver)
        try meeting.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
        receiver.begin()
        defer { receiver.end() }
        try await meeting.startCapture()
        let virtualScreen = try XCTUnwrap(windows.displays.first { $0.displayID == virtualID })
        XCTAssertTrue(windows.displays.contains { $0.displayID == display.displayID })
        XCTAssertEqual(virtualScreen.width, 1920)
        let virtualDesktop = try XCTUnwrap(NSScreen.screens.first { $0.directID == virtualID })
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 280), styleMask: .borderless,
                                   backing: .buffered, defer: false, screen: virtualDesktop)
        otherWindow.setFrameOrigin(NSPoint(x: virtualDesktop.frame.midX - 270, y: virtualDesktop.frame.midY - 140))
        otherWindow.backgroundColor = .white
        otherWindow.level = .floating
        let privateLabel = NSTextField(labelWithString: "PRIVATE WINDOW")
        privateLabel.font = .systemFont(ofSize: 32)
        privateLabel.frame = NSRect(x: 30, y: 70, width: 460, height: 60)
        otherWindow.contentView?.addSubview(privateLabel)
        otherWindow.orderFront(nil)
        defer { otherWindow.orderOut(nil) }
        let entireScreen = SCContentFilter(display: virtualScreen, excludingWindows: [])
        entireScreen.includeMenuBar = true
        let wholeConfig = SCStreamConfiguration()
        wholeConfig.width = 1280; wholeConfig.height = 720; wholeConfig.showsCursor = false
        let wholeReceiver = CaptureOutput(options: .init(microphone: false, macAudio: false)) { error in XCTFail(error.localizedDescription) }
        let wholeMeeting = SCStream(filter: entireScreen, configuration: wholeConfig, delegate: wholeReceiver)
        try wholeMeeting.addStreamOutput(wholeReceiver, type: .screen, sampleHandlerQueue: wholeReceiver.queue)
        wholeReceiver.begin()
        defer { wholeReceiver.end() }
        try await wholeMeeting.startCapture()
        func expectPage(_ phrase: String, from receiver: CaptureOutput) async throws {
            var words = ""
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(120))
                if let bytes = await receiver.screenshotForSend()?.value, let image = NSBitmapImageRep(data: bytes)?.cgImage {
                    words = try ReferenceLibrary.recognize(image)
                    if words.localizedCaseInsensitiveContains(phrase) { break }
                }
            }
            XCTAssertTrue(words.localizedCaseInsensitiveContains(phrase), "Expected \(phrase), received \(words)")
            for privateText in ["Evanto", "PRIVATE ANSWER PANEL", "PRIVATE WINDOW", "Shared Screen", "Local Share Preview", "File Edit View"] {
                XCTAssertFalse(words.localizedCaseInsensitiveContains(privateText), words)
            }
        }
        func expectMeetingPage(_ phrase: String) async throws {
            try await expectPage(phrase, from: receiver)
            try await expectPage(phrase, from: wholeReceiver)
        }
        try await expectMeetingPage("seven plus nine")
        feed.previewWindow.level = NSWindow.Level(rawValue: -88)
        feed.setPreviewVisible(true)
        try "Preview open".write(to: pageChange, atomically: true, encoding: .utf8)
        try await expectMeetingPage("Preview open")
        feed.previewWindow.performClose(nil)
        XCTAssertEqual(localCloses, 1)
        XCTAssertFalse(feed.previewWindow.isVisible)
        XCTAssertEqual(UInt32(feed.source.windowNumber), id)
        try "Preview closed".write(to: pageChange, atomically: true, encoding: .utf8)
        try await expectMeetingPage("Preview closed")
        try "What is seven plus nine?".write(to: pageChange, atomically: true, encoding: .utf8)
        try await expectMeetingPage("seven plus nine")
        try await wholeMeeting.stopCapture()
        try await meeting.stopCapture()
        otherWindow.orderOut(nil)
        let movie = directory.appendingPathComponent("filtered.mp4")
        try output.record(to: movie)
        try await Task.sleep(for: .milliseconds(380))
        _ = try await output.finishRecording()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        let recorded = try await generator.image(at: CMTime(value: 1, timescale: 10)).image
        let savedWords = try ReferenceLibrary.recognize(recorded)
        XCTAssertTrue(savedWords.localizedCaseInsensitiveContains("seven plus nine"), savedWords)
        XCTAssertFalse(savedWords.localizedCaseInsensitiveContains("PRIVATE ANSWER PANEL"))
        output.coverFilePicker(true)
        XCTAssertNil(output.screenshotForSend())
        output.coverFilePicker(false)
        try await Task.sleep(for: .milliseconds(250))
        let snapshot = await output.screenshotForSend()?.value
        let bitmap = try XCTUnwrap(snapshot.flatMap(NSBitmapImageRep.init(data:))?.cgImage)
        let sentWords = try ReferenceLibrary.recognize(bitmap)
        XCTAssertTrue(sentWords.localizedCaseInsensitiveContains("seven plus nine"), sentWords)
        XCTAssertFalse(sentWords.localizedCaseInsensitiveContains("PRIVATE ANSWER PANEL"))
        if ProcessInfo.processInfo.environment["EVANTO_TEST_CODEX"] == "1" {
            // Exercise the same Send screenshot pathway as the floating panel.
            // This stream includes only our fixture, and the library is empty.
            let state = Workspace()
            await state.codex.connect()
            defer { state.newChat(); state.codex.shutdown() }
            state.phase = .live
            state.draft = "Reply with only the word SUNDIAL."
            state.askTyped()
            state.sendScreenshot(from: output)
            XCTAssertEqual(state.exchanges.count, 2)
            XCTAssertEqual(state.panelExchange?.question.source, .screenshot)
            XCTAssertFalse(state.exchanges[0].finished)
            for _ in 0..<600 where state.answering { try await Task.sleep(for: .milliseconds(250)) }
            XCTAssertTrue(state.exchanges.allSatisfy { $0.finished && $0.issue == nil }, state.exchanges.compactMap(\.issue).joined())
            XCTAssertTrue(state.exchanges[0].answer.localizedCaseInsensitiveContains("sundial"))
            let answer = try XCTUnwrap(state.panelExchange?.answer)
            XCTAssertTrue(answer.contains("16") || answer.localizedCaseInsensitiveContains("sixteen"), answer)
            state.sendScreenshot(from: nil)
            XCTAssertTrue(state.panelExchange?.issue?.contains("No current shared frame") == true)
        }
        let chosen = SharedWindow(number: underID, owner: owner.processID)
        let windowSession = try await LiveCapture.open(displayID: display.displayID, window: chosen,
            options: .init(microphone: false, macAudio: false)) { error in XCTFail(error.localizedDescription) }
        let oldShot = try XCTUnwrap(windowSession.output.screenshotForSend())
        try "What is five times seven?".write(to: pageChange, atomically: true, encoding: .utf8)
        var nextPage = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(80))
            if let shot = await windowSession.output.screenshotForSend()?.value, let image = NSBitmapImageRep(data: shot)?.cgImage {
                nextPage = try ReferenceLibrary.recognize(image)
                if nextPage.localizedCaseInsensitiveContains("five times seven") { break }
            }
        }
        let original = await oldShot.value
        let originalImage = try XCTUnwrap(original.flatMap(NSBitmapImageRep.init(data:))?.cgImage)
        XCTAssertTrue(try ReferenceLibrary.recognize(originalImage).localizedCaseInsensitiveContains("seven plus nine"))
        XCTAssertTrue(nextPage.localizedCaseInsensitiveContains("five times seven"), nextPage)
        XCTAssertFalse(nextPage.contains("PRIVATE ANSWER PANEL"))
        await windowSession.stop()
        XCTAssertNil(windowSession.output.screenshotForSend())
        try await stream.stopCapture()
        feed.stop()
        var remaining = try await SCShareableContent.current.displays
        for _ in 0..<20 where remaining.contains(where: { $0.displayID == virtualID }) {
            try await Task.sleep(for: .milliseconds(100))
            remaining = try await SCShareableContent.current.displays
        }
        XCTAssertFalse(remaining.contains { $0.displayID == virtualID })
    }
}
