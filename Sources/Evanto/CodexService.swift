import AppKit
import Combine

enum ReplySpeed: String, CaseIterable {
    case fast = "Fast"
    case priority = "Fast with priority"
    case custom = "Selected reasoning"
}

struct ModelChoice: Identifiable {
    let id: String
    let title: String
    let images: Bool
    let efforts: [String]
    let defaultEffort: String?
    let isDefault: Bool
    var supportsPriority = false

    func effort(for preference: String) -> String? {
        if efforts.contains(preference) { return preference }
        if let defaultEffort, efforts.contains(defaultEffort) { return defaultEffort }
        return efforts.first
    }

    func replyOptions(speed: ReplySpeed, reasoning: String, usingTools: Bool) -> (effort: String?, tier: String?) {
        guard !usingTools, speed != .custom else { return (effort(for: reasoning), nil) }
        let fastEffort = ["low", "minimal", "none", "medium"].first(where: efforts.contains) ?? effort(for: reasoning)
        return (fastEffort, speed == .priority && supportsPriority ? "priority" : nil)
    }
}

@MainActor
final class CodexService: ObservableObject {
    typealias JSON = [String: Any]
    @Published private(set) var connected = false
    @Published private(set) var signedIn = false
    @Published private(set) var accountLabel = "Connecting to Codex"
    @Published private(set) var models: [ModelChoice] = []
    @Published private(set) var loginPending = false
    @Published private(set) var problem: String?

    private var process: Process?
    private var input: FileHandle?
    private var instance = UUID()
    private var nextID = 0
    private var loginID: String?
    private var disabledServers: JSON = [:]
    private let writer = DispatchQueue(label: "studio.evanto.codex.write")
    private var requests: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var replies: [String: Reply] = [:]
    private var connecting = false
    private let workingDirectory = Storage.root.appendingPathComponent("Session", isDirectory: true)

    private final class Reply {
        let thread: String
        let update: (String) -> Void
        let completion: CheckedContinuation<String, Error>
        var turn: String?
        var item: String?
        var commentary = Set<String>()
        var text = ""
        let tools: MacTools?
        var watchdog: Task<Void, Never>?
        var calls: [String: Task<ToolResult, Never>] = [:]
        var lastCall: Task<ToolResult, Never>?
        init(thread: String, tools: MacTools?, update: @escaping (String) -> Void, completion: CheckedContinuation<String, Error>) {
            self.thread = thread
            self.tools = tools
            self.update = update
            self.completion = completion
        }
    }

    func connect() async {
        guard !connecting, !connected else { return }
        connecting = true
        defer { connecting = false }
        problem = nil
        accountLabel = "Connecting to Codex"
        do {
            _ = try Storage.directory(workingDirectory)
            guard let binary = Self.executable() else {
                throw EvantoError("Install the OpenAI Codex CLI or the Codex desktop app, then choose Reconnect.")
            }
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = binary
            child.currentDirectoryURL = workingDirectory
            child.arguments = ["app-server", "--listen", "stdio://", "-c", "web_search=\"disabled\"",
                "--disable", "apps", "--disable", "plugins", "--disable", "hooks", "--disable", "shell_tool",
                "--disable", "unified_exec", "--disable", "computer_use", "--disable", "multi_agent_v2",
                "--disable", "image_generation", "--disable", "view_image", "-c", "model_provider=\"openai\""]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            child.environment = env
            child.standardInput = stdin
            child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            let token = UUID()
            instance = token
            let reader = stdout.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var bytes = Data()
                while true {
                    let batch = reader.availableData
                    if batch.isEmpty { break }
                    bytes.append(batch)
                    while let end = bytes.firstIndex(of: 10) {
                        let line = bytes[..<end]
                        if let json = try? JSONSerialization.jsonObject(with: line) as? JSON {
                            DispatchQueue.main.async { self?.receive(json, for: token) }
                        }
                        bytes.removeSubrange(...end)
                    }
                }
                DispatchQueue.main.async { self?.closed(token) }
            }
            _ = try await rpc("initialize", [
                "clientInfo": ["name": "evanto", "title": "Evanto", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0"],
                "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized", "params": [:] as JSON])
            // User-configured MCP servers are merged into the CLI config. Disable each by name
            // for the private answer threads, without changing the user's Codex settings.
            let config = try await rpc("config/read", ["includeLayers": false])["config"] as? JSON
            let servers = config?["mcp_servers"] as? JSON ?? [:]
            disabledServers = Dictionary(uniqueKeysWithValues: servers.keys.map { ($0, ["enabled": false] as JSON) })
            try await refreshAccount()
            connected = true
        } catch {
            shutdown()
            accountLabel = "Codex unavailable"
            problem = error.localizedDescription
        }
    }

    static func executable() -> URL? {
        let fm = FileManager.default
        if let embedded = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/codex"),
           fm.isExecutableFile(atPath: embedded.path) { return embedded }
        let candidates = ["/opt/homebrew", "/usr/local"].map {
            #if arch(arm64)
            let arch = "aarch64", npm = "arm64"
            #else
            let arch = "x86_64", npm = "x64"
            #endif
            return "\($0)/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-\(npm)/vendor/\(arch)-apple-darwin/bin/codex"
        } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
             "/Applications/Codex.app/Contents/Resources/codex",
             "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
          + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private func refreshAccount() async throws {
        let reply = try await rpc("account/read", ["refreshToken": false])
        let account = reply["account"] as? JSON
        signedIn = ["chatgpt", "chatgptAuthTokens"].contains(account?["type"] as? String ?? "")
        accountLabel = signedIn ? "ChatGPT" + ((account?["planType"] as? String).map { " · " + $0.capitalized } ?? "") : "Sign in with ChatGPT"
        guard signedIn else { models = []; return }
        var cursor: String?
        var available = [ModelChoice]()
        repeat {
            var params: JSON = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc("model/list", params)
            available += (result["data"] as? [JSON] ?? []).compactMap {
                guard let id = $0["model"] as? String, $0["hidden"] as? Bool != true else { return nil }
                let efforts = ($0["supportedReasoningEfforts"] as? [JSON] ?? []).compactMap { $0["reasoningEffort"] as? String }
                let tiers = ($0["serviceTiers"] as? [JSON] ?? []).compactMap { $0["id"] as? String }
                return ModelChoice(id: id, title: $0["displayName"] as? String ?? id,
                    images: ($0["inputModalities"] as? [String] ?? []).contains("image"),
                    efforts: efforts, defaultEffort: $0["defaultReasoningEffort"] as? String, isDefault: $0["isDefault"] as? Bool == true,
                    supportsPriority: tiers.contains("priority"))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        models = available
    }

    func login() async {
        if !connected { await connect() }
        guard connected, !loginPending else { return }
        problem = nil
        loginPending = true
        do {
            let result = try await rpc("account/login/start", ["type": "chatgpt"])
            guard let address = result["authUrl"] as? String, let url = URL(string: address), url.scheme == "https" else {
                throw EvantoError("Codex did not return a browser sign-in link.")
            }
            loginID = result["loginId"] as? String
            guard NSWorkspace.shared.open(url) else { throw EvantoError("Your browser could not open the ChatGPT sign-in page.") }
        } catch { loginPending = false; problem = error.localizedDescription }
    }

    func cancelLogin() async {
        if let loginID { _ = try? await rpc("account/login/cancel", ["loginId": loginID]) }
        self.loginID = nil
        loginPending = false
    }

    func answer(_ prompt: ModelInput, model: ModelChoice?, reasoning: String = "high", speed: ReplySpeed = .custom, tools: MacTools? = nil,
                accepted: @escaping () -> Void = {}, update: @escaping (String) -> Void) async throws -> String {
        guard signedIn, connected else { throw EvantoError("Sign in with ChatGPT in Settings to ask a question.") }
        var config: JSON = ["mcp_servers": disabledServers, "web_search": "disabled"]
        var start: JSON = ["cwd": workingDirectory.path, "sandbox": "read-only", "approvalPolicy": "never",
            "ephemeral": true, "environments": [], "baseInstructions": PromptBuilder.instructions]
        if let tools {
            // Keep the runtime in its empty session directory. Declare the
            // same writable folder the native tools enforce for this task.
            start["sandbox"] = "workspace-write"
            config["sandbox_workspace_write"] = [
                "writable_roots": [tools.scope.folder.standardizedFileURL.resolvingSymlinksInPath().path],
                "exclude_tmpdir_env_var": true, "exclude_slash_tmp": true, "network_access": false
            ] as JSON
            start["dynamicTools"] = tools.specifications
            start["baseInstructions"] = PromptBuilder.instructions + "\n\n" + PromptBuilder.macInstructions
        }
        start["config"] = config
        if let model { start["model"] = model.id }
        let result = try await rpc("thread/start", start)
        guard let thread = (result["thread"] as? JSON)?["id"] as? String else { throw EvantoError("Codex could not start a chat.") }
        defer { Task { _ = try? await self.rpc("thread/unsubscribe", ["threadId": thread]) } }
        try Task.checkCancellation()
        var content: [JSON] = [["type": "text", "text": prompt.text, "text_elements": []]]
        for image in prompt.images { content.append(["type": "image", "url": "data:image/jpeg;base64," + image.base64EncodedString()]) }
        var turn: JSON = ["threadId": thread, "input": content, "environments": []]
        let options = model?.replyOptions(speed: speed, reasoning: reasoning, usingTools: tools != nil)
        if let effort = options?.effort { turn["effort"] = effort }
        if let tier = options?.tier { turn["serviceTier"] = tier }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reply = Reply(thread: thread, tools: tools, update: update, completion: continuation)
                replies[thread] = reply
                armWatchdog(for: reply)
                Task {
                    do {
                        let response = try await rpc("turn/start", turn)
                        reply.turn = (response["turn"] as? JSON)?["id"] as? String
                        if replies[thread] === reply { accepted() }
                        else if let id = reply.turn {
                            _ = try? await rpc("turn/interrupt", ["threadId": thread, "turnId": id])
                        }
                    } catch { if replies[thread] === reply { finish(reply, .failure(error)) } }
                }
            }
        } onCancel: { Task { @MainActor in self.interrupt(thread) } }
    }

    private func interrupt(_ thread: String) {
        guard let reply = replies[thread] else { return }
        if let id = reply.turn { Task { _ = try? await rpc("turn/interrupt", ["threadId": thread, "turnId": id]) } }
        finish(reply, .failure(CancellationError()))
    }

    private func armWatchdog(for reply: Reply) {
        reply.watchdog?.cancel()
        reply.watchdog = Task {
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            guard replies[reply.thread] === reply else { return }
            if let id = reply.turn { Task { _ = try? await rpc("turn/interrupt", ["threadId": reply.thread, "turnId": id]) } }
            finish(reply, .failure(EvantoError("Codex stopped responding. You can send the question again.")))
        }
    }

    private func finish(_ reply: Reply, _ result: Result<String, Error>) {
        guard replies.removeValue(forKey: reply.thread) != nil else { return }
        reply.watchdog?.cancel()
        for call in reply.calls.values { call.cancel() }
        reply.completion.resume(with: result)
    }

    private func toolCall(id: Any, params: JSON, connection: UUID) {
        guard let thread = params["threadId"] as? String, let reply = replies[thread], let tools = reply.tools,
              let turn = params["turnId"] as? String, reply.turn == nil || reply.turn == turn,
              let callID = params["callId"] as? String, let name = params["tool"] as? String,
              let args = params["arguments"] as? JSON else {
            try? send(["id": id, "result": ToolResult(text: "Mac tools are available only in the current typed Mac task.", success: false).response])
            return
        }
        reply.turn = turn
        armWatchdog(for: reply)
        let call: Task<ToolResult, Never>
        if let existing = reply.calls[callID] {
            call = existing
        } else {
            // The model can request parallel actions. Serialize them within the
            // chosen window and reuse results for redelivered call IDs.
            let previous = reply.lastCall
            call = Task {
                if let previous { _ = await previous.value }
                do {
                    try Task.checkCancellation()
                    return try await tools.call(name, args)
                } catch { return ToolResult(text: error.localizedDescription, success: false) }
            }
            reply.calls[callID] = call
            reply.lastCall = call
        }
        Task {
            let result = await call.value
            guard connection == instance else { return }
            try? send(["id": id, "result": result.response])
        }
    }

    private func rpc(_ method: String, _ params: JSON) async throws -> JSON {
        guard input != nil else { throw EvantoError("Codex is disconnected. Open Settings and reconnect.") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            requests[id] = continuation
            deadlines[id] = Task {
                do { try await Task.sleep(for: .seconds(40)) } catch { return }
                deadlines.removeValue(forKey: id)
                requests.removeValue(forKey: id)?.resume(throwing: EvantoError("Codex timed out during \(method)."))
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch {
                deadlines.removeValue(forKey: id)?.cancel()
                requests.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func send(_ object: JSON) throws {
        guard let input else { throw EvantoError("Codex is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        let token = instance
        writer.async { [weak self, data] in
            do { try input.write(contentsOf: data) }
            catch { DispatchQueue.main.async { self?.closed(token) } }
        }
    }

    private func receive(_ message: JSON, for token: UUID) {
        guard instance == token else { return }
        if let method = message["method"] as? String {
            let p = message["params"] as? JSON ?? [:]
            if let id = message["id"] {
                if method == "item/tool/call" { toolCall(id: id, params: p, connection: token) }
                else { try? send(["id": id, "error": ["code": -32601, "message": "Unsupported request."] as JSON]) }
                return
            }
            if method == "account/login/completed" {
                loginPending = false
                loginID = nil
                if p["success"] as? Bool != true { problem = p["error"] as? String ?? "Sign-in was cancelled." }
            }
            if method == "account/updated" || (method == "account/login/completed" && p["success"] as? Bool == true) {
                Task { do { try await refreshAccount() } catch { problem = error.localizedDescription } }
            }
            guard let thread = p["threadId"] as? String, let reply = replies[thread] else { return }
            armWatchdog(for: reply)
            let item = p["item"] as? JSON
            switch method {
            case "turn/started":
                reply.turn = (p["turn"] as? JSON)?["id"] as? String
            case "item/started", "item/completed":
                guard item?["type"] as? String == "agentMessage", let id = item?["id"] as? String else { return }
                if item?["phase"] as? String == "commentary" { reply.commentary.insert(id); return }
                reply.item = id
                reply.text = item?["text"] as? String ?? ""
                reply.update(reply.text)
            case "item/agentMessage/delta":
                guard let id = p["itemId"] as? String, !reply.commentary.contains(id), let delta = p["delta"] as? String else { return }
                if reply.item != id { reply.item = id; reply.text = "" }
                reply.text += delta
                reply.update(reply.text)
            case "turn/completed":
                let turn = p["turn"] as? JSON
                if turn?["status"] as? String == "completed", !reply.text.isEmpty {
                    finish(reply, .success(reply.text))
                } else {
                    let message = (turn?["error"] as? JSON)?["message"] as? String
                    finish(reply, .failure(EvantoError(message ?? "Codex finished without an answer. Try again.")))
                }
            case "error":
                if p["willRetry"] as? Bool != true, let message = (p["error"] as? JSON)?["message"] as? String {
                    finish(reply, .failure(EvantoError(message)))
                }
            default: break
            }
        } else if let id = message["id"] as? Int, let request = requests.removeValue(forKey: id) {
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? JSON {
                request.resume(throwing: EvantoError(error["message"] as? String ?? "Codex rejected the request."))
            } else { request.resume(returning: message["result"] as? JSON ?? [:]) }
        }
    }

    private func closed(_ token: UUID) {
        guard token == instance else { return }
        shutdown()
        problem = "The Codex connection closed. Choose Reconnect in Settings."
    }

    func shutdown() {
        instance = UUID()
        let error = EvantoError("The Codex connection was closed.")
        deadlines.values.forEach { $0.cancel() }
        deadlines.removeAll()
        for request in requests.values { request.resume(throwing: error) }
        requests.removeAll()
        for reply in Array(replies.values) { finish(reply, .failure(error)) }
        let pipe = input
        input = nil
        try? pipe?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        connected = false
        signedIn = false
        loginPending = false
        models = []
        accountLabel = "Codex disconnected"
    }
}
