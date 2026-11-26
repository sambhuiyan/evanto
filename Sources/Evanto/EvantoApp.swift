import AppKit
import Carbon
import Combine
import CoreText
import SwiftUI

@main
enum EvantoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = Workspace()
    private var main: NSWindow!
    private var overlay: AnswerPanel?
    private var clean: CleanShareSession?
    private var status: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        let menu = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Quit Evanto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let statusMenu = NSMenu(); statusMenu.delegate = self; status.menu = statusMenu
        state.$phase.sink { [weak self] phase in
            let image = NSImage(systemSymbolName: phase == .live ? "waveform.circle.fill" : "waveform.circle",
                                accessibilityDescription: phase == .live ? "Evanto live" : "Evanto")
            image?.isTemplate = true
            self?.status.button?.image = image
            self?.status.button?.toolTip = phase == .live ? "Evanto · Live" : "Evanto"
            if phase == .live, let main = self?.main {
                main.orderOut(nil)
            }
        }.store(in: &subscriptions)
        main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        main.title = "Evanto"
        main.titleVisibility = .hidden
        main.titlebarAppearsTransparent = true
        main.delegate = self
        main.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        main.isMovableByWindowBackground = true
        main.isReleasedWhenClosed = false
        main.minSize = NSSize(width: 790, height: 520)
        main.contentView = NSHostingView(rootView: WorkspaceView(state: state, service: state.codex).ignoresSafeArea())
        main.center()
        main.setFrameAutosaveName("EvantoWorkspace")
        state.$overlayVisible.removeDuplicates().sink { [weak self] visible in self?.setOverlay(visible) }.store(in: &subscriptions)
        state.$panelPresentation.removeDuplicates().dropFirst().sink { [weak self] presentation in
            guard let self else { return }
            overlay?.orderOut(nil)
            overlay = nil
            if state.overlayVisible { showOverlay(presentation) }
        }.store(in: &subscriptions)
        state.locatePanel.sink { [weak self] in self?.bringPanelHere() }.store(in: &subscriptions)
        state.$cleanShareActive.removeDuplicates().sink { [weak self] active in self?.setCleanShare(active) }.store(in: &subscriptions)
        state.$cleanPreviewVisible.removeDuplicates().sink { [weak self] visible in self?.clean?.setPreviewVisible(visible) }.store(in: &subscriptions)
        registerShortcut()
        showMain()
        Task { await state.launch() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            // A second quit can arrive while the recording is being finalized.
            while state.savingRecording { try? await Task.sleep(for: .milliseconds(80)) }
            await state.stop()
            state.codex.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    @objc private func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSScreen.workDisplays.contains(where: { $0.visibleFrame.intersection(main.frame).width >= 160 && $0.visibleFrame.intersection(main.frame).height >= 100 }),
           let area = NSScreen.workDisplays.first?.visibleFrame {
            main.setFrameOrigin(NSPoint(x: area.midX - main.frame.width / 2, y: area.midY - main.frame.height / 2))
        }
        main.deminiaturize(nil); main.makeKeyAndOrderFront(nil)
        main.orderFrontRegardless()
    }

    private func setOverlay(_ visible: Bool) {
        guard visible else { overlay?.orderOut(nil); return }
        showOverlay(state.panelPresentation)
    }

    private func showOverlay(_ presentation: PanelPresentation) {
        if overlay == nil {
            let panel = AnswerPanel(state: state, presentation: presentation)
            positionPanel(panel)
            panel.setFrameAutosaveName(presentation == .native ? "EvantoNativeAnswerPanel" : "EvantoAnswerPanel")
            overlay = panel
        }
        guard let panel = overlay else { return }
        if !NSScreen.workDisplays.contains(where: { $0.visibleFrame.contains(panel.frame) }) { positionPanel(panel) }
        panel.present()
    }

    private func positionPanel(_ panel: NSPanel) {
        let displays = NSScreen.workDisplays
        let screen = displays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? displays.first
        guard let area = screen?.visibleFrame else { return }
        let width = min(panel.frame.width, area.width - 40), height = min(panel.frame.height, area.height - 48)
        panel.setFrame(NSRect(x: area.maxX - width - 20, y: area.maxY - height - 24, width: width, height: height), display: false)
    }

    @objc private func bringPanelHere() {
        if !state.overlayVisible { state.overlayVisible = true }
        guard let panel = overlay else { return }
        positionPanel(panel)
        panel.present()
    }

    private func setCleanShare(_ active: Bool) {
        guard active, let capture = state.capture else {
            clean?.stop()
            clean = nil
            state.cleanPreviewVisible = false
            return
        }
        clean = CleanShareSession(output: capture.output, size: capture.size, onDisplayStatus: { [weak self] status in
            self?.state.shareDisplayStatus = status
        }) { [weak self] in
            self?.state.cleanPreviewVisible = false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            action.target = self; action.isEnabled = enabled; menu.addItem(action)
        }
        menu.autoenablesItems = false
        item("Open Evanto", #selector(showMain))
        if state.answering { item("Stop Current Response or Task", #selector(stopAnswer)) }
        item(state.overlayVisible ? "Hide Answer Panel   ⌥⇧Space" : "Show Answer Panel   ⌥⇧Space", #selector(toggleOverlay))
        item("Bring Answer Panel to This Display", #selector(bringPanelHere))
        menu.addItem(.separator())
        item(state.live ? "Stop Live Session" : "Start Live Session", #selector(toggleLive), enabled: state.phase == .idle || state.live)
        item(state.micOn ? "Mute Microphone" : "Unmute Microphone", #selector(toggleMic), enabled: !state.changingInputs)
        item(state.macOn ? "Mute Mac Audio" : "Unmute Mac Audio", #selector(toggleMac), enabled: !state.changingInputs)
        item("Send Screenshot", #selector(sendScreenshot), enabled: state.live)
        item("Answer Now", #selector(answerNow), enabled: state.live)
        item(state.cleanPreviewVisible ? "Hide Local Preview" : "Show Local Preview", #selector(togglePreview), enabled: state.cleanShareActive)
        item(state.cleanShareActive ? "Stop Share Source" : "Start Share Source", #selector(toggleClean), enabled: state.live)
        item(state.recording ? "Finish Recording" : "Record Clean MP4…", #selector(toggleRecord), enabled: state.live && !state.savingRecording)
        menu.addItem(.separator())
        item("Quit Evanto", #selector(quit))
    }
    @objc private func toggleOverlay() { state.overlayVisible.toggle() }
    @objc private func toggleLive() { Task { if state.live { await state.stop() } else { await state.start() } } }
    @objc private func toggleMic() { Task { await state.setInput(.microphone, on: !state.micOn) } }
    @objc private func toggleMac() { Task { await state.setInput(.system, on: !state.macOn) } }
    @objc private func sendScreenshot() { state.sendScreenshot() }
    @objc private func answerNow() { state.answerNow() }
    @objc private func stopAnswer() { state.cancelAnswer() }
    @objc private func togglePreview() { state.cleanPreviewVisible.toggle() }
    @objc private func toggleClean() { state.cleanShareActive.toggle() }
    @objc private func toggleRecord() {
        if state.recording { Task { await state.stopRecording() } } else { state.startRecording() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let token = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(target, { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let read = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard read == noErr, key.signature == 0x45564E54, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in owner.toggleOverlay() }
            return noErr
        }, 1, &spec, token, &handler)
        let id = EventHotKeyID(signature: 0x45564E54, id: 1)
        if installed != noErr || RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey), id, target, 0, &hotKey) != noErr {
            state.notice = "The panel shortcut is already in use. You can toggle the answer panel from the menu bar."
        }
    }
}
