import AppKit
import AVFoundation
import EvantoDisplay

enum ShareDisplayStatus { case preparing, ready, windowOnly }

extension NSScreen {
    var directID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static var workDisplays: [NSScreen] { screens.filter { !EVShareDisplay.isShareDisplay($0.directID) } }
}

@MainActor
final class ShareVideoView: NSView {
    let video = AVSampleBufferDisplayLayer()
    private let leadingInset: CGFloat

    init(leadingInset: CGFloat = 0) {
        self.leadingInset = leadingInset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        video.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        layer?.addSublayer(video)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = NSRect(x: leadingInset, y: 0, width: max(0, bounds.width - leadingInset), height: bounds.height)
        CATransaction.commit()
    }
}

@MainActor
class ShareOutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The meeting captures this window by ID for the duration of a share.
/// Only its transparent leading edge intersects the user's physical displays.
@MainActor
final class SharedScreenWindow: ShareOutputWindow {
    static let pickerTitle = "Shared Screen"
    private static let transparentEdge: CGFloat = 1
    let picture = ShareVideoView(leadingInset: transparentEdge)
    private let pixelSize: CGSize

    init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        title = Self.pickerTitle
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        canHide = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = picture
        placeBesideDisplay()
        orderBack(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(placeBesideDisplay),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func placeBesideDisplay() {
        guard let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return }
        let scale = screen.backingScaleFactor
        let size = NSSize(width: ceil(pixelSize.width / scale) + Self.transparentEdge,
                          height: ceil(pixelSize.height / scale))
        let origin = NSPoint(x: screen.frame.maxX - Self.transparentEdge, y: screen.frame.midY - size.height / 2)
        setFrame(NSRect(origin: origin, size: size), display: true)
        picture.layoutSubtreeIfNeeded()
    }
}

/// A separate desktop for pickers that enumerate displays under Entire Screen.
/// The projection is ordered exclusively on the extended software display.
@MainActor
private final class ShareProjection {
    let device: EVShareDisplay
    let picture = ShareVideoView()
    private var window: ShareOutputWindow?

    init?() {
        guard let device = EVShareDisplay(name: SharedScreenWindow.pickerTitle, width: 1920, height: 1080) else { return nil }
        self.device = device
    }

    private func projectionWindow(on screen: NSScreen) -> ShareOutputWindow {
        let window = ShareOutputWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                                       backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.hasShadow = false
        window.canHide = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = picture
        return window
    }

    func place() -> Bool {
        let id = device.displayID
        guard EVShareDisplay.isShareDisplay(id), CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0,
              CGDisplayIsBuiltin(id) == 0, id != CGMainDisplayID(),
              let screen = NSScreen.screens.first(where: { $0.directID == id }) else { window?.orderOut(nil); return false }
        // An NSWindow created before AppKit registers this screen can belong to
        // the MacBook's Space even at the correct global coordinates.
        if window == nil { window = projectionWindow(on: screen) }
        guard let window else { return false }
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        picture.layoutSubtreeIfNeeded()
        return window.screen?.directID == id
    }

    func close() { window?.close(); window = nil }
}

@MainActor
final class CleanShareSession: NSObject, NSWindowDelegate {
    let source: SharedScreenWindow
    private(set) lazy var previewWindow = makePreviewWindow()
    private lazy var previewPicture = ShareVideoView()
    private var showingPreview = false
    private var stopped = false
    private var projection: ShareProjection?
    private var projectionReady = false
    var displayID: CGDirectDisplayID? { projection?.device.displayID }
    private var placementTask: Task<Void, Never>?
    private let onDisplayStatus: (ShareDisplayStatus) -> Void
    private let output: CaptureOutput
    private let size: CGSize
    private let onPreviewClosed: () -> Void

    init(output: CaptureOutput, size: CGSize, onDisplayStatus: @escaping (ShareDisplayStatus) -> Void,
         onPreviewClosed: @escaping () -> Void) {
        self.output = output
        self.size = size
        self.onPreviewClosed = onPreviewClosed
        self.onDisplayStatus = onDisplayStatus
        source = SharedScreenWindow(pixelSize: size)
        super.init()
        projection = ShareProjection()
        updateDestinations()
        NotificationCenter.default.addObserver(self, selector: #selector(placeProjection),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        placeProjection()
    }

    @objc private func placeProjection() {
        placementTask?.cancel()
        guard let projection else { onDisplayStatus(.windowOnly); return }
        if projection.place() { projectionReady = true; updateDestinations(); onDisplayStatus(.ready); return }
        projectionReady = false
        updateDestinations()
        onDisplayStatus(.preparing)
        placementTask = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, let projection = self.projection else { return }
                if projection.place() {
                    self.projectionReady = true
                    self.updateDestinations()
                    self.onDisplayStatus(.ready)
                    return
                }
            }
            self?.projection?.close()
            self?.projection = nil
            self?.updateDestinations()
            self?.onDisplayStatus(.windowOnly)
        }
    }

    private func updateDestinations() {
        var renderers = [source.picture.video.sampleBufferRenderer]
        if projectionReady, let projection { renderers.append(projection.picture.video.sampleBufferRenderer) }
        if showingPreview { renderers.append(previewPicture.video.sampleBufferRenderer) }
        output.display(on: renderers)
    }

    private func makePreviewWindow() -> NSWindow {
        let displays = NSScreen.workDisplays
        let screen = displays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? displays.first
        let width = min(CGFloat(640), (screen?.visibleFrame.width ?? 720) * 0.7)
        let height = min(width * size.height / size.width, (screen?.visibleFrame.height ?? 640) * 0.7)
        let frame = NSRect(x: 0, y: 0, width: height * size.width / size.height, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false, screen: screen)
        window.title = "Local Share Preview"
        window.contentAspectRatio = size
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = previewPicture
        if let area = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        return window
    }

    func setPreviewVisible(_ visible: Bool) {
        guard visible != showingPreview else { return }
        showingPreview = visible
        updateDestinations()
        if visible {
            previewWindow.orderFront(nil)
        } else {
            previewWindow.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard showingPreview else { return }
        showingPreview = false
        updateDestinations()
        onPreviewClosed()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        NotificationCenter.default.removeObserver(self)
        placementTask?.cancel()
        setPreviewVisible(false)
        output.display(on: [])
        source.close()
        projection?.close()
        projection = nil
    }
}
