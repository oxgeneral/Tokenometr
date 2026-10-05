import Foundation

/// Counts only live public-text deltas. Stored turns, completed-message payloads,
/// reasoning, tools and server usage never establish an arrival sample.
final class CLIStream {
    let threadID: String
    var name = L("Terminal session")
    var model = "Codex"
    var reasoningEffort: String?
    var connected = false
    private let tokenizer: Tokenizer
    private var text = ""
    private var itemID: String?
    private var turnID: String?
    private var finishedItems: [String] = []
    private var finishedTurns: [String] = []
    private var meter = LiveMeter()
    private var dirty = false
    private var measuredAt = 0.0
    private(set) var measurementID: String?
    private(set) var lastArrival = 0.0
    private(set) var changes = 0
    var onFragmentReplaced: ((String, MeterReading) -> Void)?

    init(threadID: String, tokenizer: Tokenizer) { self.threadID = threadID; self.tokenizer = tokenizer }

    func metadata(_ value: [String: Any]) {
        if let name = value["name"] as? String, !name.isEmpty { self.name = name }
        if let model = value["model"] as? String, !model.isEmpty { self.model = model }
        if let effort = (value["reasoningEffort"] ?? value["effort"]) as? String, !effort.isEmpty {
            reasoningEffort = effort
        }
    }

    @discardableResult func receive(_ method: String, _ params: [String: Any], at now: Double) -> Bool {
        guard params["threadId"] as? String == threadID else { return false }
        if method == "thread/settings/updated", let settings = params["threadSettings"] as? [String: Any] {
            metadata(settings); return false
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
            if id == turnID { finish() }
            finishedTurns.append(id); finishedTurns = Array(finishedTurns.suffix(16)); return false
        }
        if method == "item/completed", let item = params["item"] as? [String: Any],
           let id = item["id"] as? String, ["agentMessage", "plan"].contains(item["type"] as? String ?? "") {
            if id == itemID, params["turnId"] as? String == turnID { finish() }
            finishedItems.append(id); finishedItems = Array(finishedItems.suffix(64)); return false
        }
        guard ["item/agentMessage/delta", "item/plan/delta"].contains(method),
              let item = params["itemId"] as? String, let turn = params["turnId"] as? String,
              let delta = params["delta"] as? String, !delta.isEmpty,
              !finishedItems.contains(item), !finishedTurns.contains(turn) else { return false }
        if item != itemID || turn != turnID {
            if let id = measurementID, let reading = reading(at: now) { onFragmentReplaced?(id, reading) }
            text = ""; meter = LiveMeter(); dirty = false; measuredAt = 0
            itemID = item; turnID = turn; measurementID = UUID().uuidString
        }
        guard text.utf8.count + delta.utf8.count <= 8 * 1024 * 1024 else { finish(); return false }
        text += delta; dirty = true; lastArrival = now; changes += 1
        if measuredAt == 0 || now - measuredAt >= 0.25 { measure() }
        return true
    }

    func reading(at now: Double) -> MeterReading? {
        if dirty, now - measuredAt >= 0.25 { measure() }
        return measurementID == nil ? nil : meter.reading(at: now)
    }

    func finish() { measure(); meter.finish() }

    private func measure() {
        guard dirty else { return }
        meter.update(tokens: tokenizer.count(text), at: lastArrival)
        measuredAt = lastArrival; dirty = false
    }
}
