import AppKit
import Speech
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum WorkspacePage: String, CaseIterable {
    case live = "Live session", library = "Reference library", settings = "Settings"
    var icon: String {
        switch self { case .live: "waveform"; case .library: "books.vertical"; case .settings: "slider.horizontal.3" }
    }
}
enum SessionPhase { case idle, starting, live, stopping }

enum PanelPresentation: String {
    case protectedVideo, native
}

@MainActor
final class Workspace: ObservableObject {
    let codex = CodexService()
    @Published var page: WorkspacePage = .live
    @Published var phase: SessionPhase = .idle
    @Published var changingInputs = false
    @Published var micOn = UserDefaults.standard.object(forKey: "micOn") as? Bool ?? true
    @Published var macOn = UserDefaults.standard.object(forKey: "macOn") as? Bool ?? true
    @Published var autoAnswer = UserDefaults.standard.object(forKey: "autoAnswer") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoAnswer, forKey: "autoAnswer")
            if !autoAnswer {
                for task in partialDebounce.values { task.cancel() }
                partialDebounce.removeAll()
                pendingSpeechText.removeAll()
                if let inputs = speechOutput?.speechInputs() {
                    for input in inputs.values { skipHeardSpeech(from: input) }
                }
                pending.removeAll { $0.source.isSpoken }
                queued = pending.count
            }
        }
    }
    @Published var replyPause = ReplyPause(rawValue: UserDefaults.standard.integer(forKey: "replyPauseSeconds")) ?? .standard {
        didSet {
            UserDefaults.standard.set(replyPause.rawValue, forKey: "replyPauseSeconds")
            pendingSpeechText.removeAll()
            if let inputs = speechOutput?.speechInputs() {
                for input in inputs.values where canAnswer(input) { scheduleSpeechReply(from: input) }
            }
        }
    }
    @Published var speechLanguage = UserDefaults.standard.string(forKey: "speechLanguage") ?? "en_US" {
        didSet {
            guard speechLanguage != oldValue else { return }
            UserDefaults.standard.set(speechLanguage, forKey: "speechLanguage")
            guard live, let output = speechOutput else { return }
            output.resetSpeech(Set(output.speechInputs().keys))
            prepareSpeech(from: output)
        }
    }
    @Published private(set) var speechLanguages: [String] = []

    func loadSpeechLanguages() async {
        var identifiers = await SpeechTranscriber.supportedLocales.map(\.identifier)
        if !identifiers.contains("bn_BD") { identifiers.append("bn_BD") }
        speechLanguages = identifiers.sorted {
            speechLanguageName($0).localizedStandardCompare(speechLanguageName($1)) == .orderedAscending
        }
    }
    func speechLanguageName(_ id: String) -> String {
        if id == "bn_BD" { return "বাংলা (বাংলাদেশ) · Bangla (Bangladesh)" }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    @Published var modelID = UserDefaults.standard.string(forKey: "answerModel") ?? "" {
        didSet { UserDefaults.standard.set(modelID, forKey: "answerModel") }
    }
    @Published var reasoning = UserDefaults.standard.string(forKey: "reasoningEffort") ?? "high" {
        didSet { UserDefaults.standard.set(reasoning, forKey: "reasoningEffort") }
    }
    @Published var replySpeed = ReplySpeed(rawValue: UserDefaults.standard.string(forKey: "replySpeed") ?? "") ?? .fast {
        didSet { UserDefaults.standard.set(replySpeed.rawValue, forKey: "replySpeed") }
    }
    @Published var macTaskMode = false
    @Published var toolsFolder = UserDefaults.standard.url(forKey: "toolsFolder") ?? Storage.root.appendingPathComponent("Workspace", isDirectory: true)
    @Published var targetPID: pid_t = 0
    @Published private(set) var checkingCursor = false
    @Published var applications: [NSRunningApplication] = []
    @Published private var panelQuestionID: UUID?
    @Published var displayID = CGMainDisplayID()
    @Published var sharedWindow: SharedWindow?
    @Published private(set) var shareWindows: [SharedWindowChoice] = []
    @Published var files: [ReferenceFile] = []
    @Published var importing = false
    @Published var exchanges: [Exchange] = []
    @Published var draft = ""
    @Published var busy = false
    @Published var queued = 0
    @Published private(set) var speechLog = SpeechTranscript()
    @Published var speechStatus = ""
    @Published var speechFailed = false
    @Published var overlayVisible = false
    @Published var panelPresentation = PanelPresentation(rawValue: UserDefaults.standard.string(forKey: "panelPresentation") ?? "") ?? .protectedVideo {
        didSet { UserDefaults.standard.set(panelPresentation.rawValue, forKey: "panelPresentation") }
    }
    let locatePanel = PassthroughSubject<Void, Never>()
    @Published var cleanShareActive = false
    @Published var cleanPreviewVisible = false
    @Published var shareDisplayStatus: ShareDisplayStatus = .preparing
    @Published var recording = false
    @Published var savingRecording = false
    @Published var savedRecording: URL?
    @Published var notice: String?
    @Published private(set) var screenAccessBlocked = false
    @Published var startedAt: Date?

    private(set) var capture: LiveCapture?
    private let screenAccess = ScreenAccess()
    private var speechTasks: [UUID: Task<Void, Never>] = [:]
    private var captionStreams: [AudioSource: UUID] = [:]
    private var speechReady = Set<UUID>()
    private var speechIssues: [AudioSource: (UUID, String)] = [:]
    private var speechToken = UUID(), sessionToken = UUID(), chatToken = UUID()
    private var partialDebounce: [UUID: Task<Void, Never>] = [:]
    private var replyCursors: [UUID: SpokenReplyCursor] = [:]
    private var pendingSpeechText: [UUID: String] = [:]
    private weak var speechOutput: CaptureOutput?
    private var answerTask: Task<Void, Never>?
    private var screenshotTasks: [UUID: Task<Void, Never>] = [:]
    private var liveActivity: NSObjectProtocol?
    private var currentQuestion: Question?
    private struct Pending {
        let question: Question
        let heard: String
        let image: Task<Data?, Never>?
        let model: ModelChoice?
        let reasoning: String
        let speed: ReplySpeed
        let scope: MacTaskScope?
        var source: QuestionSource { question.source }
    }
    private var pending: [Pending] = []
    private var recentlyAsked: [String: Date] = [:]
    var live: Bool { phase == .live }
    var options: CaptureOptions { CaptureOptions(microphone: micOn, macAudio: macOn) }
    var selectedModel: ModelChoice? {
        codex.models.first { $0.id == modelID } ?? codex.models.first(where: \.isDefault) ?? codex.models.first
    }
    var speechContext: String { speechLog.text }
    func caption(for source: AudioSource) -> String? {
        guard let id = captionStreams[source] else { return nil }
        return speechLog.segments.last { $0.stream == id }?.text
    }

    var interim: String { latestSpokenTurn(unansweredOnly: autoAnswer)?.turn.text ?? "" }

    var panelExchange: Exchange? {
        exchanges.last(where: { $0.id == panelQuestionID }) ?? exchanges.last
    }
    var otherPanelReply: Exchange? {
        let source: QuestionSource = panelExchange?.question.source == .macAudio ? .screenshot : .macAudio
        return exchanges.last { $0.question.source == source }
    }
    func showOtherPanelReply() {
        if let exchange = otherPanelReply { panelQuestionID = exchange.id }
    }
    var answering: Bool { busy || exchanges.contains { !$0.finished && $0.question.source == .screenshot } }
    private var visionModel: ModelChoice? {
        if let model = selectedModel, model.images { return model }
        return codex.models.first { $0.isDefault && $0.images } ?? codex.models.first { $0.images }
    }

    func refreshApplications() {
        applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func refreshShareWindows() async {
        guard phase == .idle, CGPreflightScreenCaptureAccess() else { return }
        do { shareWindows = try await LiveCapture.windowChoices() }
        catch { notice = error.localizedDescription }
    }

    func chooseToolsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for Mac tasks"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if runPicker(panel) == .OK, let url = panel.url {
            toolsFolder = url
            UserDefaults.standard.set(url, forKey: "toolsFolder")
        }
    }

    func testCursor() async {
        guard !checkingCursor, !answering else { return }
        checkingCursor = true
        defer { checkingCursor = false }
        do {
            try screenAccess.ensure()
            try await DesktopTools.testInput()
            notice = "Verified cursor movement, a click, and text entry in Evanto’s test window."
        } catch { notice = error.localizedDescription }
    }

    func launch() async {
        refreshApplications()
        do { files = try await Task.detached(priority: .utility) { try ReferenceLibrary.load() }.value }
        catch { notice = "The reference library could not be read. " + error.localizedDescription }
        await codex.connect()
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        notice = nil
        screenAccessBlocked = false
        savedRecording = nil
        let token = UUID()
        sessionToken = token
        resetTranscription()
        recentlyAsked.removeAll()
        do {
            try screenAccess.ensure()
            if micOn, !(await microphoneAccess()) {
                micOn = false
                notice = "Microphone access is off. You can enable it in System Settings → Privacy & Security → Microphone."
            }
            let session = try await LiveCapture.open(displayID: displayID, window: sharedWindow, options: options) { [weak self] error in
                guard let self, self.sessionToken == token else { return }
                Task { await self.stop(); self.notice = "Display capture ended. " + error.localizedDescription }
            }
            guard sessionToken == token else { await session.stop(); return }
            capture = session
            liveActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Transcribing a user-started Evanto live session")
            phase = .live
            startedAt = Date()
            overlayVisible = true
            cleanShareActive = true
            prepareSpeech()
        } catch {
            guard sessionToken == token else { return }
            phase = .idle
            let issue = ScreenAccess.captureError(error)
            screenAccessBlocked = issue is ScreenPermissionNeeded
            notice = issue.localizedDescription
        }
    }

    private func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func setInput(_ channel: AudioSource, on: Bool) async {
        guard phase == .idle || phase == .live, !changingInputs else { return }
        changingInputs = true
        defer { changingInputs = false }
        if channel == .microphone, on, live, !(await microphoneAccess()) {
            notice = "Enable Evanto in System Settings → Privacy & Security → Microphone."
            return
        }
        switch channel {
        case .microphone: micOn = on; UserDefaults.standard.set(on, forKey: "micOn")
        case .system: macOn = on; UserDefaults.standard.set(on, forKey: "macOn")
        }
        queued = pending.count
        guard let capture else { return }
        do {
            try await capture.change(options)
            if !micOn && !macOn {
                pending.removeAll { $0.source.isSpoken }
                queued = pending.count
            }
            prepareSpeech()
        } catch {
            await stop()
            notice = "The audio change could not be applied. Capture stopped. " + error.localizedDescription
        }
    }

    func retrySpeech() {
        guard live, let output = capture?.output else { return }
        output.resetSpeech(Set(speechIssues.keys))
        prepareSpeech()
    }

    private func prepareSpeech() {
        guard let output = capture?.output else { return }
        prepareSpeech(from: output)
    }

    func prepareSpeech(from output: CaptureOutput) {
        guard live else { return }
        speechOutput = output
        let epoch = speechToken
        let inputs = output.speechInputs()
        captionStreams = inputs.mapValues(\.id)
        speechIssues = speechIssues.filter { source, issue in
            guard source == .system ? macOn : micOn else { return false }
            return inputs[source].map { $0.id == issue.0 } ?? true
        }
        let language = speechLanguage
        for (source, input) in inputs where speechTasks[input.id] == nil && speechIssues[source] == nil {
            speechTasks[input.id] = Task {
                do {
                    try await LocalSpeech.transcribe(input, language: language) {
                        guard self.speechToken == epoch else { return }
                        self.speechReady.insert(input.id)
                        self.refreshSpeechStatus()
                    } onResult: { update in
                        guard self.speechToken == epoch else { return }
                        self.heard(update, from: input)
                    }
                } catch {
                    if !Task.isCancelled, speechToken == epoch, output.speechInputs()[source] === input {
                        output.abandon(input)
                        speechIssues[source] = (input.id, error.localizedDescription)
                    }
                }
                guard speechToken == epoch else { return }
                speechLog.finish(input.id)
                partialDebounce.removeValue(forKey: input.id)?.cancel()
                replyCursors.removeValue(forKey: input.id)
                pendingSpeechText.removeValue(forKey: input.id)
                speechTasks.removeValue(forKey: input.id)
                speechReady.remove(input.id)
                refreshSpeechStatus()
            }
        }
        refreshSpeechStatus()
    }

    private func refreshSpeechStatus() {
        let inputs = speechOutput?.speechInputs() ?? [:]
        let problems = AudioSource.allCases.compactMap { source -> String? in
            guard let issue = speechIssues[source] else { return nil }
            return source.rawValue + " — " + issue.1
        }
        speechFailed = !problems.isEmpty
        if speechFailed { speechStatus = problems.joined(separator: "\n") }
        else if inputs.isEmpty { speechStatus = "" }
        else if inputs.values.allSatisfy({ speechReady.contains($0.id) }) { speechStatus = "Listening" }
        else { speechStatus = "Preparing " + speechLanguageName(speechLanguage) + " transcription. Audio is buffered on this Mac." }
    }

    private func resetTranscription() {
        speechToken = UUID()
        captionStreams.removeAll()
        for task in speechTasks.values { task.cancel() }
        for task in partialDebounce.values { task.cancel() }
        speechTasks.removeAll(); partialDebounce.removeAll(); speechReady.removeAll(); speechIssues.removeAll()
        replyCursors.removeAll(); pendingSpeechText.removeAll(); speechOutput = nil
        speechLog = SpeechTranscript()
        speechStatus = ""; speechFailed = false
    }

    func stop() async {
        guard phase == .live || phase == .starting else { return }
        phase = .stopping
        sessionToken = UUID()
        pending.removeAll { !$0.source.typedByUser }
        queued = pending.count
        if let question = currentQuestion, !question.source.typedByUser { answerTask?.cancel() }
        for task in screenshotTasks.values { task.cancel() }
        for task in partialDebounce.values { task.cancel() }
        partialDebounce.removeAll()
        cleanShareActive = false
        if recording { await stopRecording() }
        await capture?.stop()
        capture = nil
        speechOutput = nil
        if let liveActivity { ProcessInfo.processInfo.endActivity(liveActivity); self.liveActivity = nil }
        startedAt = nil
        // The input streams are closed. Allow each recognizer to finalize its
        // last sentence while the workspace is already available again.
        refreshSpeechStatus()
        phase = .idle
    }

    private func heard(_ update: SpeechUpdate, from input: SpeechInput) {
        _ = speechLog.apply(update, stream: input.id, source: input.source)
        guard live, speechOutput?.speechInputs()[input.source] === input else { return }
        guard autoAnswer else { skipHeardSpeech(from: input); return }
        scheduleSpeechReply(from: input)
    }

    private func scheduleSpeechReply(from input: SpeechInput) {
        let cursor = replyCursors[input.id] ?? SpokenReplyCursor()
        let turns = cursor.pending(in: speechLog, stream: input.id, pause: replyPause)
        guard let latest = turns.last else {
            partialDebounce.removeValue(forKey: input.id)?.cancel()
            pendingSpeechText.removeValue(forKey: input.id)
            return
        }
        for earlier in turns.dropLast() { respond(to: earlier, from: input) }
        let key = Questions.key(latest.text)
        guard pendingSpeechText[input.id] != key else { return }
        pendingSpeechText[input.id] = key
        partialDebounce[input.id]?.cancel()
        let pause = replyPause.duration
        let now = ContinuousClock.now
        // Count silence that has already elapsed during on-device decoding.
        // Leave a short stabilization window for a final wording revision.
        let quietEnd = speechOutput?.lastAudibleTime(for: input)?.advanced(by: pause) ?? now.advanced(by: pause)
        let deadline = max(now.advanced(by: .milliseconds(400)), min(now.advanced(by: pause), quietEnd))
        partialDebounce[input.id] = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                // Recognition can lag behind the speaker. Give the next
                // sentence time to arrive, even after a finalized question.
                // A steady music/noise bed must still allow a settled reply.
                let noiseDeadline = deadline.advanced(by: .seconds(3))
                while let sound = speechOutput?.lastAudibleTime(for: input) {
                    let until = min(sound.advanced(by: pause), noiseDeadline)
                    if until <= .now { break }
                    try await Task.sleep(until: until, clock: .continuous)
                }
            } catch { return }
            guard canAnswer(input),
                  let turn = (replyCursors[input.id] ?? SpokenReplyCursor()).pending(in: speechLog, stream: input.id, pause: replyPause).last else { return }
            pendingSpeechText.removeValue(forKey: input.id)
            respond(to: turn, from: input)
        }
    }

    private func skipHeardSpeech(from input: SpeechInput) {
        let cursor = replyCursors[input.id] ?? SpokenReplyCursor()
        if let last = cursor.pending(in: speechLog, stream: input.id, pause: replyPause).last {
            replyCursors[input.id, default: SpokenReplyCursor()].consume(last)
        }
    }

    private func latestSpokenTurn(unansweredOnly: Bool) -> (input: SpeechInput, turn: SpokenTurn)? {
        guard let inputs = speechOutput?.speechInputs() else { return nil }
        return inputs.values.compactMap { input -> (input: SpeechInput, turn: SpokenTurn)? in
            let cursor = unansweredOnly ? replyCursors[input.id] ?? SpokenReplyCursor() : SpokenReplyCursor()
            guard let turn = cursor.pending(in: speechLog, stream: input.id, pause: replyPause).last else { return nil }
            return (input, turn)
        }.max { $0.turn.end < $1.turn.end }
    }

    private func canAnswer(_ input: SpeechInput) -> Bool {
        live && autoAnswer && speechOutput?.speechInputs()[input.source] === input
    }

    private func respond(to turn: SpokenTurn, from input: SpeechInput) {
        guard canAnswer(input) else { return }
        if Questions.shouldAnswer(turn, from: input.source) {
            let source: QuestionSource = input.source == .system ? .macAudio : .speech
            guard automatic(turn.text, source) else { return }
        }
        finishSpokenTurn(turn, from: input)
    }

    private func finishSpokenTurn(_ turn: SpokenTurn, from input: SpeechInput) {
        replyCursors[input.id, default: SpokenReplyCursor()].consume(turn)
        pendingSpeechText.removeValue(forKey: input.id)
        partialDebounce.removeValue(forKey: input.id)?.cancel()
    }

    private func automatic(_ text: String, _ source: QuestionSource) -> Bool {
        guard live, autoAnswer, codex.signedIn else { return false }
        let key = Questions.key(text), now = Date()
        recentlyAsked = recentlyAsked.filter { now.timeIntervalSince($0.value) < 120 }
        if recentlyAsked[key] != nil { return true }
        guard pending.count < 12 else { return false }
        recentlyAsked[key] = now
        enqueue(Question(text: text, source: source))
        return true
    }

    func askTyped() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, requireAccount() else { return }
        var scope: MacTaskScope?
        if macTaskMode {
            let app = applications.first { $0.processIdentifier == targetPID && !$0.isTerminated }
            guard targetPID == 0 || app != nil else { notice = "The selected app quit. Choose another app for this task."; return }
            if app != nil && visionModel == nil { notice = "Cursor control needs an image-capable model on your account."; return }
            do {
                if app != nil { try screenAccess.ensure() }
                if UserDefaults.standard.url(forKey: "toolsFolder") == nil { _ = try Storage.directory(toolsFolder) }
                guard try toolsFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw EvantoError("Choose a folder for this Mac task.") }
            } catch { notice = error.localizedDescription; return }
            scope = MacTaskScope(folder: toolsFolder, application: app)
        }
        draft = ""
        enqueue(Question(text: text, source: macTaskMode ? .macTask : .typed), scope: scope)
    }

    func answerNow() {
        guard live, requireAccount() else { return }
        guard let (input, turn) = latestSpokenTurn(unansweredOnly: false) else {
            notice = "There’s no speech to answer yet. Choose Send screenshot to ask about the shared page."
            return
        }
        let source: QuestionSource = input.source == .system ? .macAudio : .speech
        let key = Questions.key(turn.text)
        finishSpokenTurn(turn, from: input)
        if let existing = exchanges.last(where: { $0.question.source == source && $0.issue == nil && Questions.key($0.question.text) == key }) {
            panelQuestionID = existing.id
        } else if !pending.contains(where: { $0.source == source && Questions.key($0.question.text) == key }) {
            recentlyAsked[key] = Date()
            enqueue(Question(text: turn.text, source: source))
        }
    }

    private func requireAccount() -> Bool {
        if codex.signedIn { return true }
        notice = "Connect your ChatGPT account to get answers."
        page = .settings
        return false
    }

    func sendScreenshot() { sendScreenshot(from: capture?.output) }

    func sendScreenshot(from output: CaptureOutput?) {
        guard live else { return }
        let question = Question(text: "Answer the question in this screenshot.", source: .screenshot)
        func fail(_ message: String) {
            var exchange = Exchange(question)
            exchange.issue = message
            exchange.finished = true
            exchanges.append(exchange)
            panelQuestionID = question.id
        }
        guard codex.signedIn else { fail("Sign in with ChatGPT in Evanto Settings to send a screenshot."); return }
        guard let model = visionModel else { fail("Your account needs an image-capable model to send a screenshot."); return }
        guard let image = output?.screenshotForSend() else {
            fail("No current shared frame. Make the selected window visible or close the file picker, then try again.")
            return
        }
        let item = Pending(question: question, heard: "", image: image, model: model, reasoning: reasoning, speed: replySpeed, scope: nil)
        startAnswer(item)
    }

    private func enqueue(_ question: Question, scope: MacTaskScope? = nil) {
        let passive = live && scope == nil
        let model = scope?.application != nil ? visionModel : selectedModel
        let item = Pending(question: question, heard: passive && (micOn || macOn) ? speechContext : "",
            image: nil,
            model: model, reasoning: reasoning, speed: replySpeed, scope: scope)
        if question.source.typedByUser {
            pending.insert(item, at: pending.firstIndex { !$0.source.typedByUser } ?? pending.endIndex)
        } else { pending.append(item) }
        queued = pending.count
        runNext()
    }

    private func runNext() {
        guard !busy, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        queued = pending.count
        busy = true
        currentQuestion = item.question
        startAnswer(item)
    }

    private func startAnswer(_ item: Pending) {
        let question = item.question, isScreenshot = item.source == .screenshot
        let token = chatToken, references = files
        let history = isScreenshot ? "" : exchanges.filter { $0.finished && $0.issue == nil && !$0.answer.isEmpty }.suffix(8).map {
            "User: \(String($0.question.text.prefix(1200)))\nAssistant: \(String($0.answer.prefix(3000)))"
        }.joined(separator: "\n")
        var exchange = Exchange(question)
        if isScreenshot { exchange.activity = "Sending screenshot…" }
        if item.source == .macAudio { exchange.activity = "Answering Mac audio…" }
        exchanges.append(exchange)
        panelQuestionID = question.id
        let task = Task { [self] in
            @MainActor func change(_ update: (inout Exchange) -> Void) {
                guard chatToken == token, let index = exchanges.firstIndex(where: { $0.id == question.id }) else { return }
                update(&exchanges[index])
            }
            do {
                let screenshot = await item.image?.value
                try Task.checkCancellation()
                if isScreenshot && screenshot == nil { throw EvantoError("Could not encode the screenshot. Click Send screenshot to try again.") }
                let prompt = await Task.detached(priority: .userInitiated) {
                    let body = PromptBuilder.build(question: question, files: references, heard: item.heard,
                        screenshot: screenshot, supportsImages: item.model?.images ?? false)
                    let prefix = history.isEmpty ? "" : "Previous conversation:\n" + history + "\n\n"
                    return ModelInput(text: prefix + body.text, images: body.images)
                }.value
                try Task.checkCancellation()
                let tools = item.scope.map { scope in
                    MacTools(scope: scope, images: item.model?.images ?? false) { activity in change { $0.activity = activity } }
                }
                let answer = try await codex.answer(prompt, model: item.model, reasoning: item.reasoning, speed: item.speed, tools: tools, accepted: {
                    if isScreenshot { change { $0.activity = "Reading screenshot…" } }
                }) { text in
                    change { $0.answer = text }
                }
                try Task.checkCancellation()
                change { $0.answer = answer }
            } catch {
                change { $0.issue = error is CancellationError ? "Answer stopped." : error.localizedDescription }
            }
            guard chatToken == token else { return }
            change { $0.finished = true }
            if isScreenshot {
                screenshotTasks.removeValue(forKey: question.id)
            } else {
                busy = false
                currentQuestion = nil
                answerTask = nil
                runNext()
            }
        }
        if isScreenshot { screenshotTasks[question.id] = task } else { answerTask = task }
    }

    func cancelAnswer() {
        if let answerTask { answerTask.cancel() }
        else if let item = exchanges.last(where: { !$0.finished && $0.question.source == .screenshot }) { screenshotTasks[item.id]?.cancel() }
    }

    func newChat() {
        chatToken = UUID()
        answerTask?.cancel()
        for task in screenshotTasks.values { task.cancel() }
        screenshotTasks.removeAll()
        answerTask = nil; currentQuestion = nil; panelQuestionID = nil; busy = false
        pending = []; queued = 0; exchanges = []; draft = ""
        resetTranscription()
        if live {
            capture?.output.resetSpeech(Set(AudioSource.allCases))
            prepareSpeech()
        }
        recentlyAsked.removeAll()
    }

    func importFiles() async {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Add reference files"
        panel.prompt = "Add to Library"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard runPicker(panel) == .OK else { return }
        importing = true
        defer { importing = false }
        var errors = [String]()
        for url in panel.urls {
            do { files.append(try await Task.detached(priority: .userInitiated) { try ReferenceLibrary.add(url) }.value) }
            catch { errors.append(url.lastPathComponent + " — " + error.localizedDescription) }
        }
        if !errors.isEmpty { notice = errors.joined(separator: "\n") }
    }

    func remove(_ file: ReferenceFile) {
        do { try ReferenceLibrary.remove(file); files.removeAll { $0.id == file.id } }
        catch { notice = error.localizedDescription }
    }

    func startRecording() {
        guard live, let capture, !recording, !savingRecording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Evanto \(Date().formatted(.iso8601.year().month().day())) \(Date().formatted(date: .omitted, time: .shortened).replacingOccurrences(of: ":", with: "-")).mp4"
        panel.prompt = "Record"
        guard runPicker(panel) == .OK, let url = panel.url, live else { return }
        do { try capture.output.record(to: url); recording = true; savedRecording = nil }
        catch { notice = error.localizedDescription }
    }

    func stopRecording() async {
        guard recording, !savingRecording else { return }
        savingRecording = true
        defer { recording = false; savingRecording = false }
        do { savedRecording = try await capture?.output.finishRecording() }
        catch { notice = "Recording could not be saved. " + error.localizedDescription }
    }

    private func runPicker(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        // macOS may host this dialog in a separate process. Keep the last clean
        // frame on the shared surface until the picker has closed.
        let output = capture?.output
        output?.coverFilePicker(true)
        defer { panel.orderOut(nil); output?.coverFilePicker(false) }
        panel.animationBehavior = .none
        return panel.runModal()
    }
}
