import SwiftUI
import AppKit
import AVFoundation

private func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}

enum Ink {
    static let dark = Color(red: 0.10, green: 0.19, blue: 0.17)
    static let text = Color(red: 0.12, green: 0.18, blue: 0.16)
    static let muted = Color(red: 0.31, green: 0.37, blue: 0.34)
    static let green = Color(red: 0.12, green: 0.36, blue: 0.28)
    static let mint = Color(red: 0.88, green: 0.93, blue: 0.87)
    static let lime = Color(red: 0.79, green: 0.91, blue: 0.66)
    static let base = Color(red: 0.967, green: 0.970, blue: 0.950)
    static let paper = Color(red: 0.997, green: 0.997, blue: 0.984)
    static let line = Color(red: 0.83, green: 0.85, blue: 0.81)
    static let red = Color(red: 0.60, green: 0.22, blue: 0.17)
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("DMSans-Regular", size: size).weight(weight)
    }
    static func title(_ size: CGFloat) -> Font { .custom("DMSerifText-Regular", size: size) }
}

struct SignalMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let rects: [(CGFloat, CGFloat, CGFloat)] = [(0.23, 0.48, 0.72), (0.50, 0.24, 0.75), (0.77, 0.27, 0.52)]
            for (x, top, bottom) in rects {
                var p = Path()
                p.move(to: CGPoint(x: (x - 0.055) * side, y: bottom * side))
                p.addLine(to: CGPoint(x: (x + 0.055) * side, y: top * side))
                context.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: side * 0.115, lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}

struct ActionStyle: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Ink.sans(12, .semibold))
            .foregroundStyle(primary ? .white : (destructive ? Ink.red : Ink.text))
            .padding(.horizontal, 12).frame(height: 32)
            .background(primary ? (destructive ? Ink.red : Ink.green) : Ink.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : Ink.line))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}

struct WorkspaceView: View {
    @ObservedObject var state: Workspace
    @ObservedObject var service: CodexService

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    SignalMark().frame(width: 29, height: 29).foregroundStyle(Ink.lime)
                    Text("Evanto").font(Ink.title(27))
                }.foregroundStyle(.white).padding(.leading, 16).padding(.top, 43).padding(.bottom, 31)
                ForEach(WorkspacePage.allCases, id: \.self) { destination in
                    Button { state.page = destination } label: {
                        HStack(spacing: 11) {
                            Image(systemName: destination.icon).frame(width: 18)
                            Text(destination.rawValue).font(Ink.sans(13, state.page == destination ? .semibold : .regular))
                                .lineLimit(1).minimumScaleFactor(0.92)
                            Spacer()
                            if destination == .library, !state.files.isEmpty {
                                Text("\(state.files.count)").font(.caption.monospacedDigit()).opacity(0.75)
                            }
                        }.padding(.horizontal, 12).frame(height: 38)
                            .background(state.page == destination ? Color.white.opacity(0.115) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(state.page == destination ? .white : Color.white.opacity(0.76))
                        .padding(.horizontal, 10).padding(.vertical, 2)
                }
                Spacer()
                Rectangle().fill(.white.opacity(0.13)).frame(height: 1).padding(.horizontal, 18)
                Button { state.page = .settings } label: {
                    HStack(spacing: 8) {
                        Circle().fill(service.signedIn ? Ink.lime : Color.gray).frame(width: 7, height: 7)
                        Text(service.accountLabel).font(Ink.sans(11, .medium)).lineLimit(2)
                        Spacer()
                    }.padding(18).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
            }.frame(width: 192).frame(maxHeight: .infinity).background(Ink.dark)
            VStack(alignment: .leading, spacing: 0) {
                if let notice = state.notice {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(notice).textSelection(.enabled)
                            if state.screenAccessBlocked {
                                Button("Open Screen Recording Settings") { openPrivacySettings("Privacy_ScreenCapture") }
                                    .buttonStyle(.link)
                            }
                        }
                        Spacer()
                        Button { state.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                    }.font(Ink.sans(12)).foregroundStyle(Ink.text).padding(10)
                        .background(Color(red: 0.98, green: 0.92, blue: 0.79), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 25).padding(.top, 26)
                }
                switch state.page {
                case .live: LiveView(state: state, service: service)
                case .library: LibraryView(state: state)
                case .settings: SettingsView(state: state, service: service)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.base)
        }
        .foregroundStyle(Ink.text).font(Ink.sans(13)).tint(Ink.green)
        .preferredColorScheme(.light)
    }
}

private struct LiveView: View {
    @ObservedObject var state: Workspace
    @ObservedObject var service: CodexService
    @State private var showTranscript = false
    @State private var revealLiveChat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live session").font(Ink.title(34))
                    HStack(spacing: 6) {
                        Circle().fill(state.live ? Ink.green : Ink.muted.opacity(0.6)).frame(width: 6, height: 6)
                        Text(sessionLabel)
                        if let start = state.startedAt { Text(start, style: .timer).monospacedDigit() }
                    }.font(Ink.sans(12)).foregroundStyle(Ink.muted)
                }
                Spacer()
                Button { Task { if state.live { await state.stop() } else { await state.start() } } } label: {
                    Label(state.live ? "Stop live" : "Start live", systemImage: state.live ? "stop.fill" : "play.fill")
                }.buttonStyle(ActionStyle(primary: true, destructive: state.live))
                    .disabled(state.phase == .starting || state.phase == .stopping)
            }
            HStack(spacing: 8) {
                Button { state.sendScreenshot() } label: { Label("Send screenshot", systemImage: "paperplane") }
                    .buttonStyle(ActionStyle()).disabled(!state.live).help("Send one still of the current shared view")
                channel("Microphone", state.micOn ? "mic" : "mic.slash", .microphone, state.micOn)
                channel("Mac audio", state.macOn ? "speaker.wave.2" : "speaker.slash", .system, state.macOn)
            }
            if service.connected && !service.signedIn {
                HStack {
                    Text("Connect ChatGPT to receive answers.").font(Ink.sans(12)).foregroundStyle(Ink.muted)
                    Button("Sign in") { state.page = .settings }.buttonStyle(.link)
                }
            }
            if state.live && (!state.speechStatus.isEmpty && state.speechStatus != "Listening") {
                HStack {
                    if !state.speechFailed { ProgressView().controlSize(.small) }
                    Text(state.speechStatus).font(Ink.sans(11)).foregroundStyle(Ink.muted).lineLimit(3)
                    if state.speechFailed { Button("Retry speech") { state.retrySpeech() }.buttonStyle(.link) }
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Conversation").font(Ink.sans(14, .semibold))
                    if state.queued > 0 { Text("\(state.queued) queued").font(Ink.sans(11)).foregroundStyle(Ink.muted) }
                    Spacer()
                    Toggle("Auto-answer", isOn: $state.autoAnswer).toggleStyle(.switch).controlSize(.mini)
                        .font(Ink.sans(11)).help("Show text replies to Mac playback and microphone questions after a pause")
                    Divider().frame(height: 14)
                    Button { state.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.plain).help("New chat").accessibilityLabel("New chat")
                }.padding(.horizontal, 16).frame(height: 42)
                Rectangle().fill(Ink.line).frame(height: 1)
                if state.live && !revealLiveChat {
                    VStack(spacing: 10) {
                        Text("Answers are in the private panel").font(Ink.title(22))
                        Button("Bring private panel here") { state.locatePanel.send() }.buttonStyle(ActionStyle(primary: true))
                        Button("Show chat in this workspace") { revealLiveChat = true }.buttonStyle(.link)
                        Text("The workspace can appear in a full-display share.").font(Ink.sans(11)).foregroundStyle(Ink.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.exchanges.isEmpty {
                    VStack(spacing: 9) {
                        SignalMark().foregroundStyle(Ink.green).frame(width: 46, height: 46)
                            .background(Ink.mint, in: RoundedRectangle(cornerRadius: 14))
                        Text(state.live ? (state.micOn || state.macOn ? "Listening for speech" : "Ready for a screenshot") : "Ask your first question").font(Ink.title(25))
                        Text(emptyHint)
                            .font(Ink.sans(12)).foregroundStyle(Ink.muted).multilineTextAlignment(.center)
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(state.exchanges) { exchange in ChatRow(exchange: exchange) }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: state.exchanges.last?.answer) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                        .onChange(of: state.exchanges.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                if showTranscript && (!state.live || revealLiveChat) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live transcript").font(Ink.sans(11, .bold))
                        ScrollView {
                            Text(state.speechContext.isEmpty ? "Speech will appear here during a live session." : state.speechContext)
                                .font(Ink.sans(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.defaultScrollAnchor(.bottom).frame(maxHeight: 64)
                    }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(Ink.mint.opacity(0.65))
                }
                if state.macTaskMode { MacScopeView(state: state).padding(.horizontal, 14).padding(.top, 8) }
                HStack(alignment: .center, spacing: 10) {
                    Picker("Message mode", selection: $state.macTaskMode) {
                        Label("Ask", systemImage: "text.bubble").tag(false)
                        Label("Mac task", systemImage: "cursorarrow").tag(true)
                    }.labelsHidden().fixedSize().font(Ink.sans(12, .medium)).help("Choose an answer or a task on this Mac")
                    Divider().frame(height: 18)
                    TextField(state.macTaskMode ? "Describe what to do on your Mac…" : "Ask Evanto…", text: $state.draft, axis: .vertical)
                        .textFieldStyle(.plain).font(Ink.sans(14)).lineLimit(1...4).onSubmit { state.askTyped() }
                    if state.answering && state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { state.cancelAnswer() } label: { Image(systemName: "stop.fill").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).help("Stop answer")
                    } else {
                        Button { state.askTyped() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 29, height: 29).background(Ink.green, in: Circle())
                        }.buttonStyle(.plain).disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command).help("Send question (⌘ Return)").accessibilityLabel("Send question")
                    }
                }.padding(10).padding(.leading, 3).background(Ink.base, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.line)).padding(10)
            }.background(Ink.paper, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Ink.line))
            HStack(spacing: 13) {
                tool("Show answer panel", "rectangle.on.rectangle", selected: state.overlayVisible) { state.locatePanel.send() }
                tool("Transcript", "text.alignleft", selected: showTranscript) {
                    if state.live { revealLiveChat = true }
                    showTranscript.toggle()
                }
                Spacer()
                Button { state.answerNow() } label: { Label("Answer now", systemImage: "text.bubble") }
                    .buttonStyle(ActionStyle()).disabled(!state.live || state.busy)
                Menu {
                    Button(state.cleanPreviewVisible ? "Hide local preview" : "Show local preview") { state.cleanPreviewVisible.toggle() }
                        .disabled(!state.cleanShareActive)
                    Button(state.cleanShareActive ? "Stop share source" : "Start share source") { state.cleanShareActive.toggle() }
                    Button(state.recording ? "Finish Recording" : "Record Clean MP4…") {
                        if state.recording { Task { await state.stopRecording() } } else { state.startRecording() }
                    }.disabled(state.savingRecording)
                } label: { Label(state.recording ? "Recording" : "Share & record", systemImage: state.recording ? "record.circle" : "rectangle.on.rectangle.angled") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(!state.live)
                    .foregroundStyle(state.recording ? Ink.red : Ink.text).font(Ink.sans(12, .medium))
            }
            if state.cleanShareActive || state.recording || state.savedRecording != nil {
                HStack {
                    if state.cleanShareActive {
                        switch state.shareDisplayStatus {
                        case .ready: Text("Entire Screen → Shared Screen. Some browsers label the added display “Screen 2”.")
                        case .preparing: Text("Preparing the Shared Screen display…")
                        case .windowOnly: Text("The extra display is unavailable. Choose Window → Shared Screen.")
                        }
                    }
                    if let url = state.savedRecording {
                        Button("Show saved recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                    }
                }.font(Ink.sans(11)).foregroundStyle(Ink.muted)
            }
        }.padding(.horizontal, 25).padding(.top, state.notice == nil ? 28 : 10).padding(.bottom, 17)
        .onChange(of: state.live) { _, active in
            if active { revealLiveChat = false; showTranscript = false }
        }
    }

    private var emptyHint: String {
        if !state.live { return "Type below, or start live to use your screen and audio." }
        if state.macOn && state.autoAnswer { return "A text reply appears when the speaker on your Mac pauses." }
        if !state.autoAnswer && (state.micOn || state.macOn) { return "Turn on Auto-answer for automatic text replies, or choose Answer now." }
        return "Choose Send screenshot to ask about the shared page."
    }

    private var sessionLabel: String {
        switch state.phase { case .idle: "Capture is off"; case .starting: "Starting capture…"; case .live: "Live"; case .stopping: "Stopping capture…" }
    }
    private func channel(_ title: String, _ icon: String, _ channel: AudioSource, _ on: Bool) -> some View {
        Button { Task { await state.setInput(channel, on: !on) } } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(on ? Ink.green : Ink.muted)
                Text(title).font(Ink.sans(12, .medium))
                Spacer(minLength: 2)
                Text(on ? "On" : "Off").font(Ink.sans(10, .semibold)).foregroundStyle(on ? Ink.green : Ink.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(on ? Ink.mint : Ink.line.opacity(0.45), in: Capsule())
            }.padding(.horizontal, 11).frame(height: 39).background(Ink.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
        }.buttonStyle(.plain).disabled(state.changingInputs || state.phase == .starting || state.phase == .stopping)
            .accessibilityLabel(title).accessibilityValue(on ? "On" : "Off")
            .help((on ? "Mute " : "Unmute ") + title)
    }
    private func tool(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(Ink.sans(11, selected ? .bold : .medium)) }
            .buttonStyle(.plain).foregroundStyle(selected ? Ink.green : Ink.muted)
    }
}

private struct MacScopeView: View {
    @ObservedObject var state: Workspace
    var body: some View {
        HStack(spacing: 10) {
            Button { state.chooseToolsFolder() } label: {
                Label(state.toolsFolder.lastPathComponent, systemImage: "folder").lineLimit(1)
            }.help("Choose the folder for file actions · " + state.toolsFolder.path)
            Picker("Control", selection: $state.targetPID) {
                Text("Files only").tag(pid_t(0))
                ForEach(state.applications, id: \.processIdentifier) { app in
                    Text(app.localizedName ?? "App").tag(app.processIdentifier)
                }
                if state.targetPID != 0 && !state.applications.contains(where: { $0.processIdentifier == state.targetPID }) {
                    Text("App closed").tag(state.targetPID)
                }
            }.pickerStyle(.menu).fixedSize().help("Choose a running app for cursor and keyboard actions")
            Spacer()
        }.font(Ink.sans(11)).onAppear { state.refreshApplications() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in state.refreshApplications() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in state.refreshApplications() }
    }
}

private struct ChatRow: View {
    let exchange: Exchange
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(exchange.question.source.rawValue).font(Ink.sans(10, .bold)).foregroundStyle(Ink.muted)
            Text(exchange.question.text).font(Ink.sans(14, .semibold)).textSelection(.enabled)
            if exchange.answer.isEmpty && !exchange.finished {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(exchange.activity ?? "Thinking…").font(Ink.sans(12)) }.foregroundStyle(Ink.muted)
            } else if !exchange.answer.isEmpty { answerText(exchange.answer).font(Ink.sans(14)).lineSpacing(3).textSelection(.enabled) }
            if let issue = exchange.issue { Text(issue).font(Ink.sans(12)).foregroundStyle(Ink.red).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func answerText(_ text: String) -> Text {
    if let rich = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(rich) }
    return Text(text)
}

private struct LibraryView: View {
    @ObservedObject var state: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reference library").font(Ink.title(34))
                Spacer()
                Button { Task { await state.importFiles() } } label: {
                    Label(state.importing ? "Importing…" : "Add files", systemImage: "plus")
                }.buttonStyle(ActionStyle(primary: true)).disabled(state.importing)
            }
            Text("Files you add here are available in every chat.").foregroundStyle(Ink.muted)
            if state.files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.doc").font(.system(size: 27, weight: .light)).foregroundStyle(Ink.green)
                    Text("Add your CV or notes").font(Ink.title(24))
                    Text("PDFs, Office documents, text files, and images").font(Ink.sans(12)).foregroundStyle(Ink.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.files) { ref in
                            HStack(spacing: 11) {
                                Image(systemName: ref.image == nil ? "doc.text" : "photo").foregroundStyle(Ink.green)
                                    .frame(width: 34, height: 38).background(Ink.mint, in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ref.name).font(Ink.sans(13, .semibold)).lineLimit(2)
                                    Text([ref.kind, ref.added.formatted(date: .abbreviated, time: .omitted)].filter { !$0.isEmpty }.joined(separator: " · ")).font(Ink.sans(11)).foregroundStyle(Ink.muted)
                                }
                                Spacer()
                                Button { state.remove(ref) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).help("Remove \(ref.name) from future questions").accessibilityLabel("Remove \(ref.name)")
                            }.padding(13)
                            if ref.id != state.files.last?.id { Divider() }
                        }
                    }.background(Ink.paper, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.padding(25).padding(.top, 8).frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: Workspace
    @ObservedObject var service: CodexService
    @State private var displays = NSScreen.workDisplays
    @State private var screenAllowed: Bool?
    @State private var accessibilityAllowed = false
    @State private var microphoneStatus: AVAuthorizationStatus = .notDetermined
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("Settings").font(Ink.title(34))
                group("ChatGPT account") {
                    HStack {
                        Label(service.accountLabel, systemImage: service.signedIn ? "checkmark.circle" : "person.crop.circle")
                        Spacer()
                        if !service.connected { Button("Reconnect") { Task { await service.connect() } }.buttonStyle(ActionStyle()) }
                        else if !service.signedIn {
                            Button(service.loginPending ? "Cancel sign-in" : "Sign in with ChatGPT") {
                                Task { if service.loginPending { await service.cancelLogin() } else { await service.login() } }
                            }.buttonStyle(ActionStyle(primary: true))
                        }
                    }
                    if let problem = service.problem { Text(problem).font(Ink.sans(12)).foregroundStyle(Ink.red).textSelection(.enabled) }
                    if !service.models.isEmpty {
                        Divider()
                        Picker("Answer model", selection: $state.modelID) {
                            Text("Codex default").tag("")
                            ForEach(service.models) { model in Text(model.title).tag(model.id) }
                        }.pickerStyle(.menu)
                        Picker("Reply speed", selection: Binding(get: {
                            state.replySpeed == .priority && state.selectedModel?.supportsPriority != true ? .fast : state.replySpeed
                        }, set: { state.replySpeed = $0 })) {
                            Text("Fast").tag(ReplySpeed.fast)
                            if state.selectedModel?.supportsPriority == true {
                                Text("Fast with priority · higher plan usage").tag(ReplySpeed.priority)
                            }
                            Text("Use selected reasoning").tag(ReplySpeed.custom)
                        }.pickerStyle(.menu)
                        if let model = state.selectedModel, !model.efforts.isEmpty {
                            Picker(state.replySpeed == .custom ? "Reasoning" : "Mac task reasoning", selection: Binding(
                                get: { model.effort(for: state.reasoning) ?? "" },
                                set: { state.reasoning = $0 }
                            )) {
                                ForEach(model.efforts, id: \.self) { level in Text(level.capitalized).tag(level) }
                            }.pickerStyle(.menu)
                        }
                    }
                }
                group("Mac tasks") {
                    MacScopeView(state: state)
                    Text("Choose Mac task beside the message field to work with files or use the cursor in the selected app.").font(Ink.sans(12)).foregroundStyle(Ink.muted)
                    HStack {
                        Text("Cursor & keyboard")
                        Spacer()
                        Text(accessibilityAllowed ? "Allowed" : "Needs Accessibility access").foregroundStyle(Ink.muted)
                        Button(accessibilityAllowed ? "Manage" : "Enable") {
                            if !accessibilityAllowed { DesktopTools.requestAccessibility() }
                            openPrivacySettings("Privacy_Accessibility")
                        }.buttonStyle(.link).accessibilityLabel("Manage cursor and keyboard access")
                    }.font(Ink.sans(12))
                    if accessibilityAllowed {
                        Button(state.checkingCursor ? "Checking input…" : "Test cursor and keyboard") { Task { await state.testCursor() } }
                            .disabled(state.checkingCursor || state.answering)
                            .help("Move, click, and type in a temporary Evanto window")
                    }
                }
                group("Capture") {
                    Picker("Shared view", selection: $state.sharedWindow) {
                        Text("Selected display").tag(SharedWindow?.none)
                        ForEach(state.shareWindows) { choice in Text(choice.name).lineLimit(1).tag(Optional(choice.id)) }
                        if let window = state.sharedWindow, !state.shareWindows.contains(where: { $0.id == window }) {
                            Text("Previously selected window").tag(Optional(window))
                        }
                    }.disabled(state.phase != .idle)
                    if state.sharedWindow == nil {
                        Picker("Display", selection: $state.displayID) {
                            ForEach(displays, id: \.self) { screen in
                                Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
                            }
                        }.disabled(state.phase != .idle)
                    }
                    Button("Refresh windows") { Task { await state.refreshShareWindows() } }.buttonStyle(.link).disabled(state.phase != .idle)
                    Picker("Spoken language", selection: $state.speechLanguage) {
                        if !state.speechLanguages.contains(state.speechLanguage) {
                            Text(state.speechLanguageName(state.speechLanguage)).tag(state.speechLanguage)
                        }
                        ForEach(state.speechLanguages, id: \.self) { language in
                            Text(state.speechLanguageName(language)).tag(language)
                        }
                    }.task { await state.loadSpeechLanguages() }
                    if state.speechLanguage == "bn_BD" {
                        Text("Bangla captions use Bengali.AI’s Whisper model on this Mac.")
                            .font(Ink.sans(12)).foregroundStyle(Ink.muted)
                    }
                    Picker("Pause before answering", selection: $state.replyPause) {
                        ForEach(ReplyPause.allCases, id: \.self) { pause in
                            Text("\(pause.rawValue) seconds").tag(pause)
                        }
                    }
                    Text("Auto-answer keeps consecutive sentences from the same speaker together. It shows one text reply after the pause. Send screenshot sends one still of the selected view.")
                        .font(Ink.sans(12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    permission("Screen & system audio", status: screenAllowed.map { $0 ? "Allowed" : "Needs approval" } ?? "Checking…", pane: "Privacy_ScreenCapture")
                    permission("Microphone", status: micAccessLabel, pane: "Privacy_Microphone")
                }
                group("Screen sharing") {
                    Picker("Answer panel", selection: $state.panelPresentation) {
                        Text("Capture-protected video").tag(PanelPresentation.protectedVideo)
                        Text("Native panel with Clean Share").tag(PanelPresentation.native)
                    }
                    if state.panelPresentation == .native {
                        Text("Start live adds a display called Shared Screen. Select the added display under Entire Screen in your meeting. The background feed excludes the native answer panel. Sharing your built-in display directly can include the panel.")
                    } else {
                        Text("The private panel uses a capture-protected video layer. If it is invisible on your display, choose the native panel and share the added Shared Screen display.")
                    }
                    Button("Bring private panel to this display") { state.locatePanel.send() }.buttonStyle(.link)
                    Text("Record Clean MP4 excludes the panel. Click Evanto in the Dock to reopen the workspace. ⌥⇧Space shows or hides the panel.")
                        .foregroundStyle(Ink.muted)
                }
            }.padding(25).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear(perform: refreshPermissions)
        .task { await state.refreshShareWindows() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = NSScreen.workDisplays
            if state.phase == .idle, !displays.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == state.displayID }) {
                if let first = displays.first { state.displayID = first.directID }
            }
        }
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(Ink.sans(14, .bold))
            content()
        }.font(Ink.sans(13)).frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(Ink.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
    }
    private var micAccessLabel: String {
        switch microphoneStatus {
        case .authorized: "Allowed"
        case .restricted: "Restricted"
        case .denied: "Off"
        default: "Needs approval"
        }
    }
    private func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityAllowed = AXIsProcessTrusted()
    }
    private func permission(_ name: String, status: String, pane: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(status).foregroundStyle(Ink.muted)
            Button("Manage") { openPrivacySettings(pane) }.buttonStyle(.link).accessibilityLabel("Manage \(name)")
        }.font(Ink.sans(12))
    }
}

struct AnswerPanelView: View {
    @ObservedObject var state: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    SignalMark().frame(width: 21, height: 21).foregroundStyle(Ink.lime)
                    Text("Evanto").font(Ink.sans(12, .bold))
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).gesture(WindowDragGesture())
                if state.live {
                    Circle().fill(Ink.lime).frame(width: 5, height: 5)
                    Text("Live").font(Ink.sans(10))
                    Button { state.sendScreenshot() } label: {
                        Label("Send screenshot", systemImage: "paperplane.fill")
                            .font(Ink.sans(11, .semibold)).padding(.horizontal, 9).frame(height: 26)
                            .foregroundStyle(Ink.dark).background(Ink.lime, in: Capsule())
                    }.buttonStyle(.plain).fixedSize().accessibilityHint("Send one screenshot of the selected shared view to ChatGPT")
                }
                if let answer = state.panelExchange?.answer, !answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).accessibilityLabel("Copy answer")
                }
                Button { state.overlayVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Hide panel").accessibilityHint("Option Shift Space")
            }
            if state.live {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live transcript").font(Ink.sans(10, .bold)).foregroundStyle(Ink.lime)
                    ForEach(AudioSource.allCases, id: \.self) { source in
                        if (source == .system ? state.macOn : state.micOn),
                           let latest = state.caption(for: source) {
                            Text(source.rawValue + " · " + String(latest.suffix(220)))
                                .lineLimit(2).truncationMode(.head)
                        }
                    }
                    if state.speechFailed || AudioSource.allCases.allSatisfy({ state.caption(for: $0) == nil }) || (!state.macOn && !state.micOn) {
                        Text(state.speechStatus.isEmpty ? (state.macOn || state.micOn ? "Listening…" : "Audio muted") : state.speechStatus)
                            .lineLimit(2)
                    }
                }.font(Ink.sans(12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(.white.opacity(0.16))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let exchange = state.panelExchange {
                        HStack {
                            Text(exchange.question.source.rawValue)
                            Spacer()
                            if let other = state.otherPanelReply {
                                let title = other.question.source == .macAudio ? "Show Mac audio reply" : "Show screenshot reply"
                                Button(title) { state.showOtherPanelReply() }.buttonStyle(.plain).foregroundStyle(Ink.lime)
                            }
                        }.font(Ink.sans(11, .semibold)).foregroundStyle(.white.opacity(0.75))
                        Text(exchange.question.text).font(Ink.sans(12, .medium)).foregroundStyle(Ink.lime)
                        if !exchange.answer.isEmpty { answerText(exchange.answer).font(Ink.sans(16)).lineSpacing(3).textSelection(.enabled) }
                        if let issue = exchange.issue { Text(issue).font(Ink.sans(13)) }
                        if exchange.answer.isEmpty && !exchange.finished { Text(exchange.activity ?? "Thinking…").font(Ink.sans(14)) }
                    } else {
                        Text("Your answers appear here").font(Ink.title(22))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white).background(Ink.dark)
    }
}
