import Foundation

/// Observes already loaded CLI sessions on existing local daemons. It never
/// starts a daemon, loads a stored chat, supplies settings overrides or starts a
/// turn. Resume on an already loaded thread is app-server's subscription API.
final class CLIObserver {
    private let home: URL
    private let queue: DispatchQueue
    private let tokenizer: Tokenizer
    private let statistics: StatisticsStore
    private let discoverAccounts: Bool
    private var connections: [String: CLIConnection] = [:]
    private var latest: CLIStream?
    private var observedAt = 0.0
    private var lastDiscovery = -10.0
    var lastArrival: Double { observedAt }

    init(home: URL, queue: DispatchQueue, tokenizer: Tokenizer, statistics: StatisticsStore,
         discoverAccounts: Bool) {
        self.home = home; self.queue = queue; self.tokenizer = tokenizer
        self.statistics = statistics; self.discoverAccounts = discoverAccounts
    }

    func tick(at now: Double) {
        if now - lastDiscovery >= 2 {
            lastDiscovery = now
            var homes = [home]
            if discoverAccounts {
                let accounts = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/orca/codex-accounts")
                let children = (try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? []
                homes += children.sorted { $0.path < $1.path }.prefix(16).map { $0.appendingPathComponent("home") }
            }
            let paths = Set(homes.map { $0.appendingPathComponent("app-server-control/app-server-control.sock").path })
            for path in connections.keys where !paths.contains(path) || !FileManager.default.fileExists(atPath: path) {
                connections.removeValue(forKey: path)?.stop()
            }
            for path in paths where connections[path] == nil && FileManager.default.fileExists(atPath: path) && connections.count < 8 {
                let connection = CLIConnection(path: path, queue: queue, tokenizer: tokenizer)
                connection.onText = { [weak self] stream in
                    self?.latest = stream; self?.observedAt = stream.lastArrival
                }
                connection.onStream = { [weak self] stream in
                    guard let self = self else { return }
                    stream.onFragmentReplaced = { [weak self, weak stream] fragment, reading in
                        guard let self = self, let stream = stream else { return }
                        self.statistics.capture(threadID: stream.threadID, fragmentID: fragment, model: stream.model,
                            reasoningEffort: stream.reasoningEffort, reading: reading)
                    }
                    if self.latest == nil || self.latest?.threadID == stream.threadID { self.latest = stream }
                    else if self.observedAt == 0,
                       let saved = self.statistics.record(for: stream.threadID),
                       saved.recordedAt > self.latest.flatMap({ self.statistics.record(for: $0.threadID)?.recordedAt }) ?? .distantPast {
                        self.latest = stream
                    }
                }
                connections[path] = connection
            }
        }
        for connection in connections.values {
            connection.tick(at: now)
            for stream in connection.streams.values { capture(stream, at: now) }
        }
        if let stream = latest { capture(stream, at: now) }
    }

    func stop(at now: Double) {
        for connection in connections.values {
            for stream in connection.streams.values { stream.finish(); capture(stream, at: now) }
            connection.stop()
        }
        if let stream = latest { stream.finish(); capture(stream, at: now) }
    }

    private func capture(_ stream: CLIStream, at now: Double) {
        guard let id = stream.measurementID, let reading = stream.reading(at: now) else { return }
        statistics.capture(threadID: stream.threadID, fragmentID: id, model: stream.model,
            reasoningEffort: stream.reasoningEffort, reading: reading)
    }

    func state(at now: Double) -> MonitorState? {
        guard let stream = latest else { return nil }
        let reading = stream.reading(at: now), saved = statistics.record(for: stream.threadID)
        let usingSaved = reading?.canBeSaved != true && saved != nil
        var state = MonitorState()
        state.source = "Codex CLI"; state.connected = stream.connected; state.thread = stream.name
        state.model = stream.model == "Codex" ? saved?.model ?? stream.model : stream.model
        state.reasoningEffort = stream.reasoningEffort ?? saved?.reasoningEffort
        state.reading = usingSaved ? saved?.reading : reading
        state.fragmentID = usingSaved ? saved?.fragmentID : stream.measurementID
        state.observedReading = reading; state.usingSavedReading = usingSaved; state.savedAt = saved?.recordedAt
        state.changes = stream.changes
        state.note = reading == nil ? "Жду появления текста ответа"
            : reading?.streaming == true ? "Генерация · собственный замер" : "Последний фрагмент ответа"
        if usingSaved { state.note = stream.connected ? "Сохранённый замер · жду новый ответ" : "Сохранённый замер · CLI отключён" }
        else if !stream.connected { state.note = "Последний замер · CLI отключён" }
        if statistics.saveFailed, state.reading?.streaming != true { state.note = "Замер в памяти · не удалось сохранить" }
        return state
    }
}

private final class CLIConnection {
    private let socket: CodexSocket
    private let tokenizer: Tokenizer
    private var initialized = false
    private var pending: [String: (method: String, thread: String?, time: Double)] = [:]
    private var loaded: Set<String> = []
    private var attaching: Set<String> = []
    private var lastPoll = -10.0
    private(set) var streams: [String: CLIStream] = [:]
    var onText: ((CLIStream) -> Void)?
    var onStream: ((CLIStream) -> Void)?

    init(path: String, queue: DispatchQueue, tokenizer: Tokenizer) {
        self.tokenizer = tokenizer
        socket = CodexSocket(path: path, queue: queue, wire: .websocket)
        socket.onConnection = { [weak self] connected in
            guard let self = self else { return }
            self.initialized = false; self.pending = [:]; self.attaching = []; self.loaded = []
            for stream in self.streams.values { stream.finish(); stream.connected = false }
            self.streams = [:]; self.lastPoll = -10
            if connected {
                self.request("initialize", ["clientInfo": ["name": "tokenometr", "title": "Tokenometr", "version": "0.2.0"],
                    "capabilities": ["experimentalApi": true]])
            }
        }
        socket.onMessage = { [weak self] in self?.receive($0) }
    }

    func tick(at now: Double) {
        socket.connectIfNeeded()
        for (id, request) in pending where now - request.time > 8 {
            pending.removeValue(forKey: id)
            if request.method == "thread/resume", let thread = request.thread { attaching.remove(thread) }
            if request.method == "initialize" { socket.disconnect(); return }
        }
        guard initialized, now - lastPoll >= 1 else { return }
        lastPoll = now
        if !pending.values.contains(where: { $0.method == "thread/loaded/list" }) {
            request("thread/loaded/list", ["limit": 32])
        }
    }

    func stop() { socket.disconnect() }

    private func request(_ method: String, _ params: [String: Any], thread: String? = nil) {
        guard pending.count < 40 else { return }
        let id = UUID().uuidString
        pending[id] = (method, thread, monotonicTime())
        socket.send(["id": id, "method": method, "params": params])
    }

    private func inspect(_ thread: [String: Any]) {
        // Current daemon-backed CLI sessions use the app-server's historical
        // vscode source, including sessions resumed in the terminal. The socket
        // identifies the shared CLI daemon; source alone is not a UI identifier.
        guard let id = thread["id"] as? String, loaded.contains(id),
              ["cli", "vscode"].contains(thread["source"] as? String ?? ""),
              thread["threadSource"] as? String != "agent", thread["parentThreadId"] as? String == nil else { return }
        if let stream = streams[id] { stream.metadata(thread); return }
        guard streams.count + attaching.count < 8, !attaching.contains(id) else { return }
        attaching.insert(id)
        // No overrides: subscribe only to a session confirmed loaded by this
        // daemon. Exclude history so it cannot become fabricated speed data.
        request("thread/resume", ["threadId": id, "excludeTurns": true], thread: id)
    }

    private func receive(_ message: [String: Any]) {
        if let id = message["id"] as? String, let request = pending.removeValue(forKey: id) {
            guard let result = message["result"] as? [String: Any] else {
                if let thread = request.thread { attaching.remove(thread) }
                if request.method == "initialize" { socket.disconnect() }
                return
            }
            if request.method == "initialize" {
                initialized = true; socket.send(["method": "initialized"]); lastPoll = -10
            } else if request.method == "thread/loaded/list", let ids = result["data"] as? [String] {
                loaded = Set(ids)
                for id in streams.keys where !loaded.contains(id) {
                    streams[id]?.finish(); streams[id]?.connected = false
                    requestUnsubscribe(id); streams.removeValue(forKey: id)
                }
                for id in ids.prefix(32) where !pending.values.contains(where: { $0.method == "thread/read" && $0.thread == id }) {
                    self.request("thread/read", ["threadId": id], thread: id)
                }
            } else if request.method == "thread/read", let thread = result["thread"] as? [String: Any] {
                inspect(thread)
            } else if request.method == "thread/resume", let id = request.thread {
                attaching.remove(id)
                guard loaded.contains(id), let thread = result["thread"] as? [String: Any],
                      thread["id"] as? String == id,
                      ["cli", "vscode"].contains(thread["source"] as? String ?? ""),
                      thread["threadSource"] as? String != "agent", thread["parentThreadId"] as? String == nil else { return }
                let stream = CLIStream(threadID: id, tokenizer: tokenizer)
                stream.metadata(thread); stream.metadata(result); stream.connected = true
                streams[id] = stream; onStream?(stream)
            }
            return
        }
        // Server requests (approvals, tools, authentication) belong to the CLI
        // that starts turns. An observer must never answer or claim those.
        guard message["id"] == nil, let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        if method == "thread/started", let thread = params["thread"] as? [String: Any],
           let id = thread["id"] as? String {
            loaded.insert(id); inspect(thread)
        } else if let id = params["threadId"] as? String, let stream = streams[id] {
            if stream.receive(method, params, at: monotonicTime()) { onText?(stream) }
        }
    }

    private func requestUnsubscribe(_ id: String) { request("thread/unsubscribe", ["threadId": id], thread: id) }
}
