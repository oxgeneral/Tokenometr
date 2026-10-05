import Foundation

struct MonitorState: Equatable {
    var connected = false
    var source = "Codex"
    var thread = "Ожидаю Codex"
    var model = "Codex"
    var reasoningEffort: String?
    var reading: MeterReading?
    var fragmentID: String?
    var observedReading: MeterReading?
    var usingSavedReading = false
    var savedAt: Date?
    var changes = 0
    var note = "Откройте чат и запустите генерацию"
}

final class Monitor {
    private let queue = DispatchQueue(label: "Tokenometr.stream", qos: .utility, autoreleaseFrequency: .workItem)
    private let locator: ThreadLocator
    private let accumulator: StreamAccumulator
    private let statistics: StatisticsStore
    private var cli: CLIObserver!
    private var desktopArrival = 0.0
    private var socket: CodexSocket!
    private var timer: DispatchSourceTimer?
    private var clientID: String?
    private var selectedThread: LocatedThread?
    private var lastDiscovery = 0.0
    private var subscribedAt = 0.0
    private var hasSnapshot = false
    private var streamOwnerID: String?
    var onUpdate: ((MonitorState) -> Void)?

    init(home: URL, tokenizer: Tokenizer, statisticsURL: URL? = nil) {
        locator = ThreadLocator(home: home)
        accumulator = StreamAccumulator(tokenizer: tokenizer)
        statistics = StatisticsStore(fileURL: statisticsURL)
        cli = CLIObserver(home: home, queue: queue, tokenizer: tokenizer, statistics: statistics,
            discoverAccounts: home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").standardizedFileURL)
        socket = CodexSocket(path: home.appendingPathComponent("ipc/ipc.sock").path, queue: queue)
        accumulator.onFragmentReplaced = { [weak self] fragment, reading in
            guard let self = self, let thread = self.selectedThread else { return }
            self.statistics.capture(threadID: thread.id, fragmentID: fragment, model: self.accumulator.model,
                reasoningEffort: self.accumulator.reasoningEffort ?? thread.reasoningEffort, reading: reading)
        }
        socket.onConnection = { [weak self] connected in
            guard let self = self else { return }
            self.clientID = nil; self.resetStream()
            if connected {
                self.socket.send(["type": "request", "requestId": UUID().uuidString,
                                  "sourceClientId": "initializing", "version": 0,
                                  "method": "initialize", "params": ["clientType": "tokenometr"]])
            }
        }
        socket.onMessage = { [weak self] in self?.receive($0) }
    }

    func start() {
        queue.async {
            let ticker = DispatchSource.makeTimerSource(queue: self.queue)
            ticker.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(40))
            ticker.setEventHandler { [weak self] in self?.tick() }
            self.timer = ticker; ticker.resume()
        }
    }

    func stop() {
        queue.sync {
            self.archiveCurrent(at: monotonicTime())
            self.cli.stop(at: monotonicTime())
            self.statistics.flush(at: monotonicTime(), force: true)
            self.timer?.cancel(); self.timer = nil
            self.socket.disconnect()
        }
    }

    private func tick() {
        let now = monotonicTime()
        cli.tick(at: now)
        if now - lastDiscovery > 2 {
            lastDiscovery = now
            if let latest = locator.latest() {
                if latest.id != selectedThread?.id {
                    if let old = selectedThread { follow(old.id, enabled: false) }
                    resetStream(); selectedThread = latest
                    follow(latest.id, enabled: true)
                } else {
                    // Settings can change without changing the chat ID.
                    selectedThread = latest
                }
            }
            socket.connectIfNeeded()
            // A desktop window can silently lose its followers while this IPC
            // connection remains open. Renew without discarding valid readings.
            if clientID != nil, now - subscribedAt > (hasSnapshot ? 30 : 5), let thread = selectedThread {
                follow(thread.id, enabled: true)
            }
        }
        let reading = accumulator.reading(at: now)
        archiveCurrent(at: now)
        statistics.flush(at: now)
        let saved = selectedThread.flatMap { statistics.record(for: $0.id) }
        let usingSaved = reading?.canBeSaved != true && saved != nil
        var state = MonitorState()
        state.connected = clientID != nil
        state.thread = selectedThread?.name ?? "Ожидаю Codex"
        state.model = accumulator.model == "Codex" ? saved?.model ?? "Codex" : accumulator.model
        state.reasoningEffort = accumulator.reasoningEffort ?? selectedThread?.reasoningEffort
        state.reading = usingSaved ? saved?.reading : reading
        state.fragmentID = usingSaved ? saved?.fragmentID : accumulator.measurementID
        state.observedReading = reading
        state.usingSavedReading = usingSaved
        state.savedAt = saved?.recordedAt
        state.changes = accumulator.receivedChanges
        if clientID == nil { state.note = "Ожидаю подключения к Codex" }
        else if !hasSnapshot { state.note = "Ожидаю открытый чат Codex" }
        else if reading?.streaming == true { state.note = "Генерация · собственный замер" }
        else if reading != nil { state.note = "Последний фрагмент ответа" }
        else { state.note = "Жду появления текста ответа" }
        if usingSaved {
            state.note = clientID == nil ? "Сохранённый замер · Codex отключён"
                : reading != nil ? "Сохранённый замер · собираю новый"
                : "Сохранённый замер · жду новый ответ"
        }
        if statistics.saveFailed, state.reading != nil, state.reading?.streaming != true {
            state.note = "Замер в памяти · не удалось сохранить"
        }
        if let candidate = cli.state(at: now) {
            let newer = candidate.reading != nil && (cli.lastArrival > desktopArrival
                || (desktopArrival == 0 && (candidate.savedAt ?? .distantPast) > (state.savedAt ?? .distantPast)))
            if newer || (state.reading == nil && !hasSnapshot && candidate.connected) { state = candidate }
        }
        onUpdate?(state)
    }

    private func receive(_ message: [String: Any]) {
        let type = message["type"] as? String
        if type == "client-discovery-request", let request = message["requestId"] {
            socket.send(["type": "client-discovery-response", "requestId": request,
                         "response": ["canHandle": false]])
            return
        }
        if type == "request", let request = message["requestId"] {
            socket.send(["type": "response", "requestId": request, "resultType": "error", "error": "read-only-monitor"])
            return
        }
        if type == "response", message["method"] as? String == "initialize",
           let result = message["result"] as? [String: Any], let id = result["clientId"] as? String {
            clientID = id
            if let thread = selectedThread { follow(thread.id, enabled: true) }
            return
        }
        guard type == "broadcast", let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        if let targets = message["targetClientIds"] as? [String], let client = clientID, !targets.contains(client) { return }
        let source = message["sourceClientId"] as? String
        if method == "client-status-changed", let id = params["clientId"] as? String, id != clientID {
            if params["status"] as? String == "connected", let thread = selectedThread {
                follow(thread.id, enabled: true, targets: [id])
            } else if params["status"] as? String == "disconnected", id == streamOwnerID {
                resetStream()
                if let thread = selectedThread { follow(thread.id, enabled: true) }
            }
            return
        }
        if method == "ipc-connection-reset" {
            resetStream()
            if let thread = selectedThread { follow(thread.id, enabled: true) }
            return
        }
        guard params["hostId"] as? String == "local",
              params["conversationId"] as? String == selectedThread?.id,
              let thread = selectedThread else { return }
        if method == "thread-stream-following-status-requested" {
            follow(thread.id, enabled: true, targets: source.map { [$0] })
            return
        }
        guard method == "thread-stream-state-changed", let change = params["change"] as? [String: Any] else { return }
        let snapshot = change["type"] as? String == "snapshot"
        // Renewal returns an identical baseline. Replaying it would erase the
        // last speed and hover history. A window can restart at revision zero
        // even when its IPC client ID survives the renderer reload.
        if snapshot, hasSnapshot, source == streamOwnerID,
           let revision = change["revision"] as? Int, let current = accumulator.currentRevision,
           revision == current {
            // Codex can refresh settings without advancing its text revision.
            // Keep arrival samples but refresh the metadata in the snapshot.
            if let state = change["conversationState"] as? [String: Any] { accumulator.refreshMetadata(from: state) }
            return
        }
        if !snapshot, (!hasSnapshot || source != streamOwnerID) {
            resetStream(); follow(thread.id, enabled: true)
            return
        }
        if snapshot { archiveCurrent(at: monotonicTime()) }
        let changes = accumulator.receivedChanges
        if accumulator.receive(change, at: monotonicTime()) {
            if accumulator.receivedChanges > changes { desktopArrival = monotonicTime() }
            if snapshot { hasSnapshot = true; streamOwnerID = source }
        } else {
            resetStream(); follow(thread.id, enabled: true)
        }
    }

    private func resetStream() {
        archiveCurrent(at: monotonicTime())
        statistics.flush(at: monotonicTime(), force: true)
        hasSnapshot = false; streamOwnerID = nil; accumulator.reset()
    }

    private func archiveCurrent(at now: Double) {
        guard let thread = selectedThread, let fragment = accumulator.measurementID,
              let reading = accumulator.reading(at: now) else { return }
        statistics.capture(threadID: thread.id, fragmentID: fragment, model: accumulator.model,
            reasoningEffort: accumulator.reasoningEffort ?? thread.reasoningEffort, reading: reading)
    }

    private func follow(_ id: String, enabled: Bool, targets: [String]? = nil) {
        guard let client = clientID else { return }
        // Other clients joining must not postpone the broadcast renewal: a
        // targeted announcement reaches only that new client, not our owner.
        if enabled, targets == nil { subscribedAt = monotonicTime() }
        var message: [String: Any] = ["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                                     "sourceClientId": client, "params": ["conversationId": id, "hostId": "local", "following": enabled]]
        if let targets = targets { message["targetClientIds"] = targets }
        socket.send(message)
    }
}
