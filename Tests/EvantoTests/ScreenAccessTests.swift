import ScreenCaptureKit
import XCTest
@testable import Evanto

final class ScreenAccessTests: XCTestCase {
    @MainActor func testRepeatedStartChecksTheGrantAndOnlyPromptsOnce() throws {
        let access = ScreenAccess()
        var allowed = false
        var requests = 0
        let request: () -> Bool = { requests += 1; return false }

        for _ in 0..<2 {
            XCTAssertThrowsError(try access.ensure(preflight: { allowed }, request: request)) {
                XCTAssertTrue($0 is ScreenPermissionNeeded)
            }
        }
        allowed = true
        for _ in 0..<2 { try access.ensure(preflight: { allowed }, request: request) }
        XCTAssertEqual(requests, 1)

        let reopened = ScreenAccess()
        try reopened.ensure(preflight: { allowed }, request: request)
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testGrantDuringSystemPromptContinuesImmediately() throws {
        var allowed = false
        try ScreenAccess().ensure(preflight: { allowed }, request: { allowed = true; return false })
        try ScreenAccess().ensure(preflight: { false }, request: { true })
    }

    @MainActor func testOnlyADeniedScreenGrantGetsPermissionInstructions() {
        let denied = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(ScreenAccess.captureError(denied) is ScreenPermissionNeeded)
        let audio = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStartAudioCapture.rawValue)
        XCTAssertEqual(ScreenAccess.captureError(audio) as NSError, audio)
        let other = NSError(domain: "Example", code: denied.code)
        XCTAssertEqual(ScreenAccess.captureError(other) as NSError, other)
    }
}
