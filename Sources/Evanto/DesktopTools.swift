import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit

struct WindowObservation {
    let token = UUID().uuidString
    let window: CGWindowID
    let bounds: CGRect
    let width: Int
    let height: Int

    func point(x: Int, y: Int) throws -> CGPoint {
        guard (0..<width).contains(x), (0..<height).contains(y), bounds.width > 0, bounds.height > 0 else {
            throw EvantoError("The coordinates fall outside the observed window.")
        }
        return CGPoint(x: bounds.minX + (CGFloat(x) + 0.5) * bounds.width / CGFloat(width),
                       y: bounds.minY + (CGFloat(y) + 0.5) * bounds.height / CGFloat(height))
    }
}

@MainActor
final class DesktopTools {
    private let application: NSRunningApplication
    private var observation: WindowObservation?
    var name: String { application.localizedName ?? "Selected app" }

    init(_ application: NSRunningApplication) { self.application = application }

    private var pid: pid_t { application.processIdentifier }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private var windowList: [ToolJSON] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [ToolJSON] ?? []
    }

    private func frontWindow(in list: [ToolJSON]) -> CGWindowID? {
        list.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 &&
            ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    private func checkFront() throws {
        try Task.checkCancellation()
        guard !application.isTerminated, hasFocus else {
            throw EvantoError("The selected app lost focus. Observe its window again before acting.")
        }
    }

    private var hasFocus: Bool {
        if AXIsProcessTrusted() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                var focusedPID: pid_t = 0
                if AXUIElementGetPid(value as! AXUIElement, &focusedPID) == .success { return focusedPID == pid }
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func bringForward() async throws {
        if hasFocus { return }
        if pid == ProcessInfo.processInfo.processIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp?.yieldActivation(to: application)
            _ = application.activate(from: .current, options: [])
        }
        for _ in 0..<6 where !hasFocus { try await Task.sleep(for: .milliseconds(50)) }
        if !hasFocus, let url = application.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<15 where !hasFocus { try await Task.sleep(for: .milliseconds(60)) }
        }
        try checkFront()
    }

    func observe() async throws -> ToolResult {
        observation = nil
        guard !application.isTerminated else { throw EvantoError("The selected app has quit. Choose a running app.") }
        guard CGPreflightScreenCaptureAccess() else { throw ScreenPermissionNeeded() }
        try await bringForward()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let id = frontWindow(in: windowList),
              let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid }),
              window.frame.width >= 2, window.frame.height >= 2 else {
            throw EvantoError("Open a visible document window in " + name + " and retry.")
        }
        let config = SCStreamConfiguration()
        let scale = min(2, 1560 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let bitmap = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        try checkFront()
        guard let jpeg = ReferenceLibrary.jpeg(bitmap) else { throw EvantoError("The window image could not be encoded.") }
        let sight = WindowObservation(window: id, bounds: window.frame, width: bitmap.width, height: bitmap.height)
        observation = sight
        return ToolResult(text: "\(name) · \(window.title ?? "Window")\nImage \(sight.width) × \(sight.height) pixels. Observation \(sight.token).", image: jpeg)
    }

    static func testInput() async throws {
        let desktop = DesktopTools(.current)
        try await desktop.bringForward()
        let rect = NSRect(x: 0, y: 0, width: 350, height: 132)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Evanto input check"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Testing the cursor and keyboard…")
        label.frame = NSRect(x: 20, y: 91, width: 310, height: 22)
        let field = NSTextField(frame: NSRect(x: 20, y: 34, width: 310, height: 45))
        field.isEditable = true
        field.isSelectable = true
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(field)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        @MainActor func observeField() async throws -> WindowObservation {
            _ = try await desktop.observe()
            guard let sight = desktop.observation, sight.window == CGWindowID(window.windowNumber) else {
                throw EvantoError("Bring the Evanto input check window forward and try again.")
            }
            return sight
        }
        let sight = try await observeField()
        let middle = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let x = Int(CGFloat(sight.width) * middle.x / window.frame.width)
        let y = Int(CGFloat(sight.height) * (1 - middle.y / window.frame.height))
        let expected = try sight.point(x: x, y: y)
        _ = try await desktop.input(["action": "move", "observation": sight.token, "x": x, "y": y])
        guard let actual = CGEvent(source: nil)?.location, hypot(actual.x - expected.x, actual.y - expected.y) <= 3 else {
            throw EvantoError("The cursor did not reach the test window. Check Accessibility and try again.")
        }
        let click = try await observeField()
        _ = try await desktop.input(["action": "click", "observation": click.token, "x": x, "y": y])
        let type = try await observeField()
        _ = try await desktop.input(["action": "type", "observation": type.token, "text": "Evanto ✓"])
        guard (field.currentEditor()?.string ?? field.stringValue) == "Evanto ✓" else {
            throw EvantoError("The test window did not receive the typed text. Check Accessibility and try again.")
        }
    }

    private func validate(_ sight: WindowObservation, at point: CGPoint? = nil) throws {
        try checkFront()
        let windows = windowList
        guard frontWindow(in: windows) == sight.window,
              let info = windows.first(where: { $0[kCGWindowNumber as String] as? CGWindowID == sight.window }),
              Self.bounds(info) == sight.bounds else {
            throw EvantoError("The window changed. Observe it again.")
        }
        if let point {
            // Ask AppKit which window would receive the click. Bounding boxes
            // alone include transparent screen-sharing borders and shadows.
            let appKitPoint = NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
            let hit = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
            guard hit == Int(sight.window) else {
                let covering = windows.first { $0[kCGWindowNumber as String] as? Int == hit }
                let owner = covering?[kCGWindowOwnerName as String] as? String ?? "Another window"
                throw EvantoError(owner + " covers that point. Move it aside and retry.")
            }
        }
    }

    private static func bounds(_ window: ToolJSON) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    func input(_ args: ToolJSON) async throws -> ToolResult {
        guard AXIsProcessTrusted() else { throw EvantoError("Enable Evanto in System Settings → Privacy & Security → Accessibility to use the cursor and keyboard.") }
        guard let sight = observation, sight.token == (try args.string("observation")) else { throw EvantoError("Observe the selected app before this action.") }
        observation = nil
        try validate(sight)
        let action = try args.string("action")
        switch action {
        case "type": try await typeText(try args.string("text"), in: sight)
        case "key": try press(try args.string("key"))
        default:
            func point(_ x: String, _ y: String) throws -> CGPoint {
                guard let px = args[x] as? Int, let py = args[y] as? Int else { throw EvantoError("Supply pixel coordinates.") }
                let p = try sight.point(x: px, y: py)
                try validate(sight, at: p)
                return p
            }
            let start = try point("x", "y")
            guard ["move","click","right_click","double_click","drag","scroll"].contains(action) else { throw EvantoError("Unknown cursor action.") }
            try mouse(.mouseMoved, at: start)
            switch action {
            case "click", "right_click", "double_click":
                let right = action == "right_click"
                for count in 1...(action == "double_click" ? 2 : 1) {
                    try validate(sight, at: start)
                    try mouse(right ? .rightMouseDown : .leftMouseDown, at: start, right: right, count: count)
                    try mouse(right ? .rightMouseUp : .leftMouseUp, at: start, right: right, count: count)
                    if count == 1 && action == "double_click" { try await Task.sleep(for: .milliseconds(60)) }
                }
            case "scroll":
                guard let lines = args["lines"] as? Int, (-40...40).contains(lines), lines != 0,
                      let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: Int32(lines), wheel2: 0, wheel3: 0) else { throw EvantoError("Supply a scroll distance from -40 to 40 lines.") }
                event.location = start
                event.post(tap: .cghidEventTap)
            case "drag":
                let end = try point("endX","endY")
                var last = start
                try mouse(.leftMouseDown, at: start)
                defer { try? mouse(.leftMouseUp, at: last) }
                for step in 1...12 {
                    let fraction = CGFloat(step) / 12
                    let p = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                    try validate(sight, at: p)
                    try mouse(.leftMouseDragged, at: p)
                    last = p
                    try await Task.sleep(for: .milliseconds(14))
                }
            default: break
            }
        }
        try await Task.sleep(for: .milliseconds(120))
        return ToolResult(text: "Sent " + action + " to " + name + ". Observe the app to verify the result.")
    }

    private func mouse(_ type: CGEventType, at point: CGPoint, right: Bool = false, count: Int = 1) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left) else {
            throw EvantoError("macOS could not create a pointer event.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        event.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String, in sight: WindowObservation) async throws {
        guard text.utf8.count <= 16_000 else { throw EvantoError("Type up to 16 KB at a time.") }
        // A Quartz keyboard event carries at most 20 UTF-16 code units. Split on
        // scalar boundaries so a non-BMP character never straddles two events.
        var units = [UniChar]()
        func flush() throws {
            guard !units.isEmpty else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw EvantoError("Keyboard input is unavailable.") }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.postToPid(pid)
            }
            units.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            let next = String(scalar).utf16
            if units.count + next.count > 20 {
                try validate(sight)
                try flush()
                try await Task.sleep(for: .milliseconds(12))
            }
            units.append(contentsOf: next)
        }
        try validate(sight)
        try flush()
    }

    private func press(_ chord: String) throws {
        let parts = chord.lowercased().components(separatedBy: "+")
        guard let last = parts.last, let key = Self.keys[last] else { throw EvantoError("Use a letter, digit, return, tab, escape, space, backspace, delete, or an arrow key.") }
        let mods: [String: CGEventFlags] = ["command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl]
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = mods[part] else { throw EvantoError("Unknown key modifier " + part) }
            flags.insert(flag)
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down) else { throw EvantoError("Keyboard input is unavailable.") }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    private static let keys = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "space": kVK_Space,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9
    ]
}
