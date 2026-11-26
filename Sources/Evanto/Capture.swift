import AppKit
import EvantoDisplay
import AVFoundation
import CoreImage
import ScreenCaptureKit

struct CaptureOptions {
    var microphone: Bool
    var macAudio: Bool
}

struct ScreenPermissionNeeded: LocalizedError {
    var errorDescription: String? {
        "macOS hasn’t granted this copy of Evanto screen access. Enable Evanto in Screen & System Audio Recording, then choose Quit & Reopen if prompted."
    }
}

@MainActor
final class ScreenAccess {
    private var requested = false

    func ensure(preflight: () -> Bool = CGPreflightScreenCaptureAccess,
                request: () -> Bool = CGRequestScreenCaptureAccess) throws {
        if preflight() { return }
        if !requested {
            requested = true
            if request() || preflight() { return }
        }
        throw ScreenPermissionNeeded()
    }

    static func captureError(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == SCStreamError.errorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue {
            return ScreenPermissionNeeded()
        }
        return error
    }
}

// The capture queue owns the stream buffers, speech inputs, preview, and recorder.
final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "studio.evanto.capture", qos: .userInitiated)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var mixer: AudioMixer?
    private let origin = CMClockGetTime(CMClockGetHostTimeClock())
    private var inputs: [AudioSource: SpeechInput] = [:]
    private var options: CaptureOptions
    private var running = false
    private var timer: DispatchSourceTimer?
    private var frame: CMSampleBuffer?
    private var revision = 0
    private var visualPause = false
    private var resumeAfter = 0.0
    private var pickerGeneration = 0
    private var freshFrame = false
    private var cachedImage: (revision: Int, task: Task<Data?, Never>)?
    private var renderers: [AVSampleBufferVideoRenderer] = []
    private var recorder: CleanRecording?
    private let onStop: (Error) -> Void
    private let window: SharedWindow?
    private let refreshImage: (() async throws -> CGImage)?

    init(options: CaptureOptions, window: SharedWindow? = nil, refreshImage: (() async throws -> CGImage)? = nil,
         onStop: @escaping (Error) -> Void) {
        self.options = options
        self.window = window
        self.refreshImage = refreshImage
        self.onStop = onStop
        super.init()
        updateInputs(options)
    }

    func begin() { queue.sync { running = true } }

    private func bitmap(_ pixels: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        return ci.createCGImage(image, from: image.extent)
    }

    // ScreenCaptureKit owns this buffer. Retain it read-only until the JPEG is encoded.
    private struct FrozenFrame: @unchecked Sendable { let pixels: CVPixelBuffer }

    func screenshotForSend() -> Task<Data?, Never>? {
        queue.sync {
            guard running, !visualPause, CMClockGetTime(CMClockGetHostTimeClock()).seconds >= resumeAfter,
                  window?.isVisible != false else { return nil }
            guard freshFrame, let pixels = frame?.imageBuffer else {
                // The page may have changed behind a picker on a static desktop.
                // Take a new still of the same filter only in response to this click.
                guard let refreshImage else { return nil }
                let generation = pickerGeneration
                return Task.detached(priority: .userInitiated) { [self] in
                    guard let image = try? await refreshImage(), queue.sync(execute: {
                        running && !visualPause && pickerGeneration == generation && window?.isVisible != false
                    }) else { return nil }
                    return ReferenceLibrary.jpeg(image)
                }
            }
            if let cachedImage, cachedImage.revision == revision { return cachedImage.task }
            let frozen = FrozenFrame(pixels: pixels)
            let task = Task.detached(priority: .userInitiated) { [self] in
                autoreleasepool { bitmap(frozen.pixels).flatMap(ReferenceLibrary.jpeg) }
            }
            cachedImage = (revision, task)
            return task
        }
    }

    func coverFilePicker(_ open: Bool) {
        queue.sync {
            visualPause = open
            pickerGeneration &+= 1
            freshFrame = false
            if !open { resumeAfter = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.2 }
        }
    }

    private func updateInputs(_ options: CaptureOptions) {
        for source in AudioSource.allCases {
            let enabled = source == .microphone ? options.microphone : options.macAudio
            if enabled {
                if inputs[source] == nil { inputs[source] = SpeechInput(source: source, origin: origin) }
            } else { inputs.removeValue(forKey: source)?.finish() }
        }
    }

    func configure(_ new: CaptureOptions) {
        queue.sync {
            options = new
            updateInputs(new)
            mixer?.set(microphone: new.microphone, system: new.macAudio)
        }
    }

    func speechInputs() -> [AudioSource: SpeechInput] { queue.sync { inputs } }

    func lastAudibleTime(for input: SpeechInput) -> ContinuousClock.Instant? {
        queue.sync { input.lastAudibleAt }
    }

    func resetSpeech(_ sources: Set<AudioSource>) {
        queue.sync {
            for source in sources { inputs.removeValue(forKey: source)?.finish() }
            updateInputs(options)
        }
    }

    func abandon(_ input: SpeechInput) {
        queue.sync {
            if inputs[input.source] === input { input.finish() }
        }
    }

    func display(on destinations: [AVSampleBufferVideoRenderer]) {
        queue.sync {
            for removed in renderers where !destinations.contains(where: { $0 === removed }) {
                removed.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            if let frame {
                for added in destinations where !renderers.contains(where: { $0 === added }) {
                    show(frame, on: added)
                }
            }
            renderers = destinations
        }
    }

    private func show(_ frame: CMSampleBuffer, on renderer: AVSampleBufferVideoRenderer) {
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: nil, sampleBuffer: frame, sampleBufferOut: &copy) == noErr,
              let copy, !copy.sampleAttachments.isEmpty else { return }
        // A newly opened share window must also display a cached, static desktop.
        copy.sampleAttachments[0][.displayImmediately] = true
        renderer.enqueue(copy)
    }

    func record(to url: URL) throws {
        try queue.sync {
            guard recorder == nil, let pixels = frame?.imageBuffer else {
                throw EvantoError("Wait for the first display frame, then start the recording.")
            }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            recorder = try CleanRecording(to: url, firstFrame: pixels, at: now)
            mixer = AudioMixer(origin: now)
            mixer?.set(microphone: options.microphone, system: options.macAudio)
            let ticker = DispatchSource.makeTimerSource(queue: queue)
            ticker.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(5))
            ticker.setEventHandler { [weak self] in
                guard let self, let recorder = self.recorder else { return }
                self.mixer?.drain(at: CMClockGetTime(CMClockGetHostTimeClock())) { pcm, time in recorder.append(pcm, at: time) }
            }
            timer = ticker
            ticker.resume()
        }
    }

    func finishRecording() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let recorder = self.recorder else { continuation.resume(returning: nil); return }
                self.recorder = nil
                self.timer?.cancel(); self.timer = nil
                // Release the resampling delay before closing the audio track.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                self.mixer?.drain(at: now + CMTime(value: 120, timescale: 1000)) { pcm, time in
                    recorder.append(pcm, at: time)
                }
                self.mixer = nil
                recorder.finish(at: now) { continuation.resume(with: $0.map(Optional.some)) }
            }
        }
    }

    func end() {
        queue.sync {
            running = false
            timer?.cancel()
            for input in inputs.values { input.finish() }
            inputs.removeAll()
            for renderer in renderers { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
            renderers.removeAll()
            timer = nil; mixer = nil; frame = nil; cachedImage = nil
        }
    }

    // Called on queue by ScreenCaptureKit.
    func acceptAudio(_ sample: CMSampleBuffer, source: AudioSource) {
        guard let input = inputs[source], sample.numSamples > 0 else { return }
        guard let pcm = sample.copiedPCM() else {
            input.fail(EvantoError("Could not decode " + source.rawValue + " audio. Retry speech."))
            return
        }
        input.push(pcm, at: sample.presentationTimeStamp)
        mixer?.append(pcm, at: sample.presentationTimeStamp, source: source)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { self.onStop(error) } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard running, sampleBuffer.isValid else { return }
        switch type {
        case .audio, .microphone:
            acceptAudio(sampleBuffer, source: type == .audio ? .system : .microphone)
        case .screen:
            guard !visualPause, CMClockGetTime(CMClockGetHostTimeClock()).seconds >= resumeAfter else { return }
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
            if status == .blank || status == .suspended || status == .stopped {
                freshFrame = false
                cachedImage = nil
                if frame != nil {
                    frame = nil
                    for renderer in renderers { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
                }
                return
            }
            guard status == .complete || status == .started, let pixels = sampleBuffer.imageBuffer else { return }
            frame = sampleBuffer
            freshFrame = true
            revision &+= 1
            for renderer in renderers { show(sampleBuffer, on: renderer) }
            recorder?.append(pixels, at: sampleBuffer.presentationTimeStamp)
        @unknown default: break
        }
    }
}

struct SharedWindow: Hashable {
    let number: CGWindowID
    let owner: pid_t

    var isVisible: Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]]
        return info?.contains { $0[kCGWindowOwnerPID as String] as? pid_t == owner && $0[kCGWindowIsOnscreen as String] as? Bool == true } == true
    }
}

struct SharedWindowChoice: Identifiable {
    let id: SharedWindow
    let name: String
}

@MainActor
final class LiveCapture {
    let output: CaptureOutput
    let size: CGSize
    private let picture: SCStream
    private let audioConfig: SCStreamConfiguration
    private let audioFilter: SCContentFilter?
    private var separateAudio: SCStream?
    private var stopped = false

    private init(picture: SCStream, size: CGSize, output: CaptureOutput, audioFilter: SCContentFilter?, audioConfig: SCStreamConfiguration) {
        self.picture = picture
        self.size = size
        self.output = output
        self.audioFilter = audioFilter
        self.audioConfig = audioConfig
    }

    static func windowChoices() async throws -> [SharedWindowChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.frame.width > 40, window.frame.height > 40,
                  let owner = window.owningApplication, owner.processID != ProcessInfo.processInfo.processIdentifier,
                  let title = window.title, !title.isEmpty else { return nil }
            return SharedWindowChoice(id: SharedWindow(number: window.windowID, owner: owner.processID),
                                      name: owner.applicationName + " — " + title)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func open(displayID: CGDirectDisplayID, window: SharedWindow? = nil, options: CaptureOptions,
                     onStop: @escaping (Error) -> Void) async throws -> LiveCapture {
        guard !EVShareDisplay.isShareDisplay(displayID) else { throw EvantoError("Select your work display as the capture source.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApps = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        guard !ownApps.isEmpty else {
            throw EvantoError("Evanto could not identify its own windows to exclude them. Open the workspace and start again.")
        }
        var chosen: SCWindow?
        if let window {
            chosen = content.windows.first { $0.windowID == window.number && $0.owningApplication?.processID == window.owner && $0.isOnScreen }
            guard chosen != nil, !ownApps.contains(where: { $0.processID == window.owner }) else {
                throw EvantoError("The selected window is unavailable. Choose a visible window in Settings.")
            }
        }
        let display = chosen.flatMap { w in content.displays.first { $0.frame.intersects(w.frame) } } ?? content.displays.first { $0.displayID == displayID }
        guard let display else { throw EvantoError("The selected display is disconnected. Choose another display in Settings.") }
        let displayFilter = cleanFilter(display: display, excluding: ownApps)
        let pictureFilter = chosen.map { SCContentFilter(desktopIndependentWindow: $0) } ?? displayFilter
        let bounds = chosen?.frame ?? display.frame
        let config = SCStreamConfiguration()
        let scale = min(CGFloat(pictureFilter.pointPixelScale), 1920 / max(1, bounds.width), 1920 / max(1, bounds.height))
        config.width = max(2, Int(bounds.width * scale) / 2 * 2)
        config.height = max(2, Int(bounds.height * scale) / 2 * 2)
        config.ignoreShadowsSingleWindow = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 24)
        config.queueDepth = 5
        config.showsCursor = true
        config.streamName = "Evanto Live"
        let audioConfig = chosen == nil ? config : SCStreamConfiguration()
        if chosen != nil {
            audioConfig.width = 2; audioConfig.height = 2
            audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            audioConfig.streamName = "Evanto Audio"
        }
        audioConfig.capturesAudio = options.macAudio
        audioConfig.captureMicrophone = options.microphone
        audioConfig.excludesCurrentProcessAudio = true
        audioConfig.sampleRate = AudioMixer.rate
        audioConfig.channelCount = 2
        let still = SCStreamConfiguration()
        still.width = config.width; still.height = config.height
        still.ignoreShadowsSingleWindow = true
        still.showsCursor = true
        let output = CaptureOutput(options: options, window: window, refreshImage: {
            try await SCScreenshotManager.captureImage(contentFilter: pictureFilter, configuration: still)
        }, onStop: onStop)
        let picture = SCStream(filter: pictureFilter, configuration: config, delegate: output)
        try picture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        let session = LiveCapture(picture: picture, size: CGSize(width: config.width, height: config.height),
            output: output, audioFilter: chosen == nil ? nil : displayFilter, audioConfig: audioConfig)
        if chosen == nil { try session.addAudioOutputs(to: picture) }
        output.begin()
        do {
            try await picture.startCapture()
            if chosen != nil, options.macAudio || options.microphone { try await session.startSeparateAudio() }
        } catch { await session.stop(); throw error }
        return session
    }

    static func cleanFilter(display: SCDisplay, excluding applications: [SCRunningApplication]) -> SCContentFilter {
        let filter = SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
        filter.includeMenuBar = false
        return filter
    }

    private func addAudioOutputs(to stream: SCStream) throws {
        for type: SCStreamOutputType in [.audio, .microphone] {
            try stream.addStreamOutput(output, type: type, sampleHandlerQueue: output.queue)
        }
    }

    // A window filter also scopes system audio to its app. Take only audio
    // outputs from this separate stream so other Mac audio can still be heard.
    private func startSeparateAudio() async throws {
        guard let audioFilter, !stopped else { return }
        let stream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: output)
        try addAudioOutputs(to: stream)
        separateAudio = stream
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture() }
    }

    func change(_ options: CaptureOptions) async throws {
        guard !stopped else { return }
        output.configure(options)
        guard audioConfig.captureMicrophone != options.microphone || audioConfig.capturesAudio != options.macAudio else { return }
        audioConfig.captureMicrophone = options.microphone
        audioConfig.capturesAudio = options.macAudio
        if audioFilter == nil { try await picture.updateConfiguration(audioConfig) }
        else if !options.microphone && !options.macAudio {
            let old = separateAudio
            separateAudio = nil
            try await old?.stopCapture()
        } else if let separateAudio { try await separateAudio.updateConfiguration(audioConfig) }
        else { try await startSeparateAudio() }
    }

    func stop() async {
        stopped = true
        if let separateAudio { try? await separateAudio.stopCapture(); self.separateAudio = nil }
        try? await picture.stopCapture()
        output.end()
    }
}
