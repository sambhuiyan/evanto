import AppKit
import SwiftUI
import XCTest
@testable import Evanto

final class MacTaskTests: XCTestCase {
    @MainActor func testFloatingScreenshotButtonFitsTheSmallestPanel() throws {
        let state = Workspace()
        @MainActor func renderedWords() throws -> String {
            let panel = AnswerPanelView(state: state).frame(width: 310, height: 160)
            let renderer = ImageRenderer(content: panel)
            renderer.scale = 2
            return try ReferenceLibrary.recognize(XCTUnwrap(renderer.cgImage))
        }
        state.phase = .live
        XCTAssertTrue(try renderedWords().localizedCaseInsensitiveContains("Send screenshot"))
        state.phase = .idle
        XCTAssertFalse(try renderedWords().localizedCaseInsensitiveContains("Send screenshot"))
    }

    func testFileChangesStayInsideChosenFolderAndRespectLatestRevision() async throws {
        let base = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try Storage.directory(base.appendingPathComponent("chosen"))
        let files = FolderTools(root: root, images: false)
        _ = try await files.perform("make_folder", ["path":"Notes"])
        _ = try await files.perform("write_text", ["path":"Notes/brief.txt","text":"Draft α\n","revision":"new"])
        let result = try await files.perform("read_file", ["path":"Notes/brief.txt"])
        let rev = try XCTUnwrap(result.text.split(separator: "\n").first?.split(separator: " ").last)
        XCTAssertTrue(result.text.contains("Draft α\n"))
        _ = try await files.perform("write_text", ["path":"Notes/brief.txt","text":"Revised β\n","revision":String(rev)])
        do {
            _ = try await files.perform("write_text", ["path":"Notes/brief.txt","text":"Too late","revision":String(rev)])
            XCTFail("An outdated revision replaced the file")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        do {
            _ = try await files.perform("write_text", ["path":"Notes/brief.txt","text":"Overwrite","revision":"new"])
            XCTFail("Create replaced an existing file")
        } catch {}
        _ = try await files.perform("move_item", ["path":"Notes/brief.txt","destination":"Notes/summary.md"])
        let listed = try await files.perform("list_files", ["path":"Notes"])
        XCTAssertTrue(listed.text.contains("summary.md"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/summary.md"), encoding: .utf8), "Revised β\n")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base)
        for outside in ["../escape","/tmp/escape","link/escape",".hidden","Notes/../../escape"] {
            do {
                _ = try await files.perform("write_text", ["path":outside,"text":"unwanted","revision":"new"])
                XCTFail("Out-of-scope write to " + outside)
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape").path))
    }

    func testWindowPixelsMapToQuartzPointsOnAnOffsetRetinaDisplay() throws {
        let sight = WindowObservation(window: 1, bounds: CGRect(x: -800, y: 90, width: 600, height: 400), width: 1200, height: 800)
        let point = try sight.point(x: 800, y: 200)
        XCTAssertEqual(point.x, -399.75, accuracy: 0.001)
        XCTAssertEqual(point.y, 190.25, accuracy: 0.001)
        XCTAssertThrowsError(try sight.point(x: 1200, y: 799))
        XCTAssertThrowsError(try sight.point(x: 1, y: -1))
    }

    func testReasoningUsesHighWhenAvailableAndHonorsModelFallback() {
        let model = ModelChoice(id: "fixture", title: "Fixture", images: true, efforts: ["low", "medium", "high"], defaultEffort: "medium", isDefault: true)
        XCTAssertEqual(model.effort(for: "high"), "high")
        XCTAssertEqual(model.effort(for: "low"), "low")
        XCTAssertEqual(model.effort(for: "unavailable"), "medium")
    }

    func testFastRepliesRespectModelSupportAndPreserveMacTaskReasoning() {
        var model = ModelChoice(id: "test", title: "Test", images: true, efforts: ["low", "high"],
                                defaultEffort: "high", isDefault: true)
        XCTAssertEqual(model.replyOptions(speed: .fast, reasoning: "high", usingTools: false).effort, "low")
        XCTAssertNil(model.replyOptions(speed: .fast, reasoning: "high", usingTools: false).tier)
        XCTAssertNil(model.replyOptions(speed: .priority, reasoning: "high", usingTools: false).tier)
        model.supportsPriority = true
        XCTAssertEqual(model.replyOptions(speed: .priority, reasoning: "high", usingTools: false).tier, "priority")
        let task = model.replyOptions(speed: .priority, reasoning: "high", usingTools: true)
        XCTAssertEqual(task.effort, "high")
        XCTAssertNil(task.tier)
        XCTAssertEqual(model.replyOptions(speed: .custom, reasoning: "high", usingTools: false).effort, "high")
    }

    @MainActor func testChatGPTActuallyUsesFileToolsAndWritesVerifiedResult() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_CODEX"] == "1" else { throw XCTSkip("Requires a signed-in Codex runtime.") }
        let root = try Storage.directory(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "MEADOW-" + UUID().uuidString
        try marker.write(to: root.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        let service = CodexService()
        await service.connect()
        defer { service.shutdown() }
        let model = try XCTUnwrap(service.models.first(where: \.isDefault) ?? service.models.first, service.problem ?? "")
        var activities: [String] = []
        let tools = MacTools(scope: .init(folder: root, application: nil), images: model.images) { activities.append($0) }
        let prompt = PromptBuilder.build(question: Question(text: "Read fixture.txt in the chosen folder. Copy its exact contents to result.txt using your file tools and verify by reading result.txt. Reply with the marker.", source: .macTask), files: [], heard: "", screenshot: nil, supportsImages: model.images)
        let answer = try await service.answer(prompt, model: model, tools: tools) { _ in }
        XCTAssertTrue(activities.contains("Read · fixture.txt"), "\(activities) · \(answer)")
        XCTAssertTrue(activities.contains("Write · result.txt"), "\(activities) · \(answer)")
        XCTAssertTrue(activities.contains("Read · result.txt"), "\(activities) · \(answer)")
        XCTAssertTrue(answer.contains(marker), answer)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), marker)
    }

    @MainActor func testInterviewAnswerUsesStrongestWorkExampleAndProvidesFinishedStory() async throws {
        guard ProcessInfo.processInfo.environment["EVANTO_TEST_CODEX"] == "1" else { throw XCTSkip("Requires a signed-in Codex runtime.") }
        let service = CodexService()
        await service.connect()
        defer { service.shutdown() }
        let model = try XCTUnwrap(service.models.first(where: \.isDefault) ?? service.models.first)
        let fixture = ReferenceFile(id: UUID(), name: "synthetic-resume.txt", added: .now, text: """
            Latest role: Orchard sales clerk, handled inventory. Earlier role: Fern QA analyst, reproduced an intermittent calendar import failure. I compared two exported calendars, isolated an ambiguous timezone, wrote a regression case, and verified that the corrected importer preserved the meeting time. No quantitative impact recorded.
            """, image: nil)
        let prompt = PromptBuilder.build(question: Question(text: "Tell me about a time you diagnosed a difficult quality issue for a QA position.", source: .speech), files: [fixture], heard: "", screenshot: nil, supportsImages: false)
        var firstText: ContinuousClock.Instant?
        let start = ContinuousClock.now
        let answer = try await service.answer(prompt, model: model, speed: .fast) { text in
            if firstText == nil && !text.isEmpty { firstText = .now }
        }
        XCTAssertNotNil(firstText)
        if let firstText { print("Fast interview reply first text after \(start.duration(to: firstText))") }
        XCTAssertGreaterThan(answer.split(whereSeparator: \.isWhitespace).count, 75, answer)
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("calendar"), answer)
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("regression"), answer)
        XCTAssertTrue(answer.contains("I "), answer)
        XCTAssertFalse(answer.contains("[insert"), answer)
    }
}
