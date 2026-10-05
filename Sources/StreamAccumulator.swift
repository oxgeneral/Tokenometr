import Foundation

final class StreamAccumulator {
    private let tokenizer: Tokenizer
    private var texts: [String: String] = [:]
    private var types: [String: String] = [:]
    private var indexedItems: [String: String] = [:]
    private var activeItem: String?
    private var meter = LiveMeter()
    private var revision: Int?
    private var dirty = false
    private var arrivalTime = 0.0
    var model = "Codex"
    var reasoningEffort: String?
    var fragmentID: String? { activeItem }
    private(set) var measurementID: String?
    var currentRevision: Int? { revision }
    private(set) var receivedChanges = 0
    var onFragmentReplaced: ((String, MeterReading) -> Void)?

    init(tokenizer: Tokenizer) { self.tokenizer = tokenizer }

    /// Returns false when a revision gap requires a fresh baseline snapshot.
    func receive(_ change: [String: Any], at time: Double) -> Bool {
        if change["type"] as? String == "snapshot" {
            reset()
            revision = change["revision"] as? Int
            if let state = change["conversationState"] as? [String: Any] {
                refreshMetadata(from: state)
                seed(state, path: [])
            }
            return true
        }
        guard change["type"] as? String == "patches",
              let base = change["baseRevision"] as? Int,
              let newRevision = change["revision"] as? Int else { return false }
        if let current = revision, newRevision <= current { return true }
        guard base == revision, newRevision > base else { return false }
        revision = newRevision
        let patches = change["patches"] as? [[String: Any]] ?? []
        // Register new messages before processing their accepted text edits.
        for patch in patches {
            let path = pathParts(patch["path"])
            if path == ["latestModel"], let value = patch["value"] as? String { model = value }
            if path == ["latestReasoningEffort"] || path == ["latestThreadSettings", "effort"] ||
               path == ["latestCollaborationMode", "settings", "reasoning_effort"] {
                reasoningEffort = effortValue(patch["value"])
            }
            if path == ["latestThreadSettings"], let settings = patch["value"] as? [String: Any], settings["effort"] != nil {
                reasoningEffort = effortValue(settings["effort"])
            }
            if let object = patch["value"] as? [String: Any] { seed(object, path: path) }
        }
        let edits = change["acceptedTextChanges"] as? [[String: Any]] ?? []
        var changedIDs = Set<String>()
        for edit in edits {
            guard let key = edit["key"] as? [String: Any], let id = key["itemId"] as? String,
                  let target = edit["target"] as? [String: Any], target["field"] as? String == "text",
                  types[id] == "agentMessage" || types[id] == "plan",
                  let operations = edit["edits"] as? [[String: Any]] else { continue }
            guard let result = applyingTextEdits(operations, to: texts[id] ?? "") else { return false }
            accept(result, id: id, at: time)
            changedIDs.insert(id)
        }
        // Older desktop builds may send full text replacements without edits.
        for patch in patches {
            let path = pathParts(patch["path"])
            if path.last == "text", let text = patch["value"] as? String,
               let id = indexedItems[indexKey(Array(path.dropLast()))],
               !changedIDs.contains(id), types[id] == "agentMessage" || types[id] == "plan" {
                accept(text, id: id, at: time)
            }
            if path.contains("agentMessageCompletedAtMsById"), path.last == activeItem {
                measure(); meter.finish()
            }
            // Only a turn's own status can end its response. Tool item status
            // lives below `items` and can change independently of generation.
            if path.last == "status", !path.contains("items"),
               ((path.first == "turns" && path.count == 3) ||
                (path.prefix(3) == ["turnHistory", "history", "entitiesByKey"] && path.count == 5)),
               let value = patch["value"] as? String,
               ["completed", "interrupted", "failed"].contains(value) {
                measure(); meter.finish()
            }
        }
        return true
    }

    func reading(at time: Double) -> MeterReading? {
        measure()
        return activeItem == nil ? nil : meter.reading(at: time)
    }

    /// Metadata can be refreshed independently of text arrival samples.
    func refreshMetadata(from state: [String: Any]) {
        model = state["latestModel"] as? String ?? "Codex"
        let settings = state["latestThreadSettings"] as? [String: Any]
        let collaboration = state["latestCollaborationMode"] as? [String: Any]
        let modeSettings = collaboration?["settings"] as? [String: Any]
        reasoningEffort = effortValue(state["latestReasoningEffort"])
            ?? effortValue(settings?["effort"]) ?? effortValue(modeSettings?["reasoning_effort"])
    }

    private func effortValue(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    func reset() {
        texts.removeAll(); types.removeAll(); indexedItems.removeAll()
        activeItem = nil; measurementID = nil; meter = LiveMeter(); revision = nil; dirty = false
        model = "Codex"; reasoningEffort = nil
    }

    private func accept(_ text: String, id: String, at time: Double) {
        guard text != texts[id] else { return }
        if text.isEmpty || activeItem != id, let previous = activeItem {
            // A second message can start before the next display tick. Keep
            // its predecessor before replacing the text or the meter.
            measure(); onFragmentReplaced?(measurementID ?? previous, meter.reading(at: time))
        }
        texts[id] = text
        receivedChanges += 1
        if text.isEmpty {
            if activeItem == id {
                activeItem = nil; measurementID = nil; meter = LiveMeter(); dirty = false
            }
            return
        }
        let firstObservation = activeItem != id
        if firstObservation { activeItem = id; measurementID = UUID().uuidString; meter = LiveMeter() }
        dirty = true; arrivalTime = time
        // The first observation is recorded immediately, before display batching.
        // A cached snapshot has no observed arrival time and cannot be a sample.
        if firstObservation { measure() }
    }

    private func measure() {
        guard dirty, let id = activeItem, let text = texts[id] else { return }
        meter.update(tokens: tokenizer.count(text), at: arrivalTime)
        dirty = false
    }

    private func seed(_ value: Any, path: [String]) {
        if let dict = value as? [String: Any] {
            if let type = dict["type"] as? String, ["agentMessage", "plan"].contains(type),
               let id = dict["id"] as? String {
                types[id] = type
                indexedItems[indexKey(path)] = id
                // A full completion item must not erase already accepted edits.
                if texts[id] == nil { texts[id] = dict["text"] as? String ?? "" }
                return
            }
            // Keep only structural conversation fields, never tool output or prompts.
            for key in ["turns", "turnHistory", "history", "entitiesByKey", "items"] {
                if let child = dict[key] { seed(child, path: path + [key]) }
            }
            if path.last == "entitiesByKey" {
                for (key, child) in dict { seed(child, path: path + [key]) }
            }
        } else if let array = value as? [Any] {
            // Baseline only needs recent messages, not a full conversation archive.
            for i in array.indices.suffix(64) { seed(array[i], path: path + [String(i)]) }
        }
    }

    private func pathParts(_ value: Any?) -> [String] {
        guard let parts = value as? [Any] else { return [] }
        return parts.map { String(describing: $0) }
    }

    private func indexKey(_ path: [String]) -> String { path.joined(separator: "\u{1f}") }
}
