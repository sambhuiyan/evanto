import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
private final class VideoSurface: NSView {
    let display = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        display.preventsCapture = true
        display.videoGravity = .resize
        layer = display
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The AppKit view tree handles input and accessibility. Its compositor layer
/// stays transparent. Only the capture-protected video layer presents pixels.
@MainActor
final class ProtectedHostingView<Content: View>: NSView {
    private let host: NSHostingView<Content>
    private let interaction = NSView()
    private let surface = VideoSurface(frame: .zero)
    var video: AVSampleBufferDisplayLayer { surface.display }
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var changes = Set<AnyCancellable>()
    private var events: Any?
    private var windowChanges: [NSObjectProtocol] = []
    private var drawScheduled = false
    private var refreshUntil = ContinuousClock.now
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var pixelSize: CGSize = .zero

    init(rootView: Content, state: Workspace) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        interaction.wantsLayer = true
        let transparent = CALayer()
        transparent.actions = ["opacity": NSNull()]
        transparent.opacity = 0
        interaction.layer = transparent
        interaction.addSubview(host)
        addSubview(interaction)

        addSubview(surface, positioned: .above, relativeTo: interaction)
        state.objectWillChange.sink { [weak self] _ in self?.refresh() }.store(in: &changes)
        state.codex.objectWillChange.sink { [weak self] _ in self?.refresh() }.store(in: &changes)
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        interaction.frame = bounds
        host.frame = interaction.bounds
        surface.frame = bounds
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let events { NSEvent.removeMonitor(events); self.events = nil }
        let center = NotificationCenter.default
        for observer in windowChanges { center.removeObserver(observer) }
        windowChanges.removeAll()
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowChanges.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Local SwiftUI state, scrolling, and typing can change what is visible
        // without publishing a workspace change. Snapshot after event dispatch.
        events = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged, .mouseMoved]) { [weak self, weak window] event in
            if let window, event.window === window { self?.refresh() }
            return event
        }
        refresh()
    }

    func refresh() {
        guard window?.isVisible == true, window?.isMiniaturized == false else { return }
        // A short burst covers layout and scroll animations. An idle window
        // keeps its last protected frame without a permanent rendering timer.
        refreshUntil = .now.advanced(by: .milliseconds(160))
        if !drawScheduled { scheduleFrame(after: .milliseconds(0)) }
    }

    private func scheduleFrame(after delay: DispatchTimeInterval) {
        drawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            drawScheduled = false
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            renderFrame()
            if .now < refreshUntil { scheduleFrame(after: .milliseconds(40)) }
        }
    }

    private func renderFrame() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let renderer = video.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage, let sample = sampleBuffer(for: image) else { return }
        renderer.enqueue(sample)
    }

    private func sampleBuffer(for image: CGImage) -> CMSampleBuffer? {
        // Supply a native bi-planar video surface for the protected display
        // path. The panel's background is opaque within this video frame.
        let width = (image.width + 1) & ~1, height = (image.height + 1) & ~1
        let size = CGSize(width: width, height: height)
        if pixelSize != size || pool == nil {
            pool = nil
            format = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            pixelSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        ci.render(CIImage(cgImage: image), to: buffer, bounds: CGRect(origin: .zero, size: size),
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        sample.sampleAttachments[0][.displayImmediately] = true
        return sample
    }

    deinit {
        if let events { NSEvent.removeMonitor(events) }
        for observer in windowChanges { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
final class AnswerPanel: NSPanel {
    init(state: Workspace, presentation: PanelPresentation) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 410, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        title = "Evanto Answers"
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .floating
        minSize = NSSize(width: 310, height: 120)
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        let answers = AnswerPanelView(state: state)
        switch presentation {
        case .native:
            // Clean Share excludes our process. Some other recorders also honor
            // this window flag. Set it before attaching any answer content.
            sharingType = .none
            isOpaque = true
            backgroundColor = NSColor(Ink.dark)
            contentView = NSHostingView(rootView: answers)
        case .protectedVideo:
            isOpaque = false
            backgroundColor = .clear
            contentView = ProtectedHostingView(rootView: answers, state: state)
        }
    }

    func present() {
        if isMiniaturized { deminiaturize(nil) }
        orderFrontRegardless()
        contentView?.layoutSubtreeIfNeeded()
        displayIfNeeded()
        (contentView as? ProtectedHostingView<AnswerPanelView>)?.refresh()
    }
}
