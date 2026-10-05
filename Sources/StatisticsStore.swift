import Foundation

struct SavedStatistics: Codable, Equatable {
    let fragmentID: String
    let model: String
    let reasoningEffort: String?
    let recordedAt: Date
    let reading: MeterReading
}

/// Keeps one measured fragment per chat, never conversation text. All access
/// belongs to the monitor's serial queue; disk writes are coalesced.
final class StatisticsStore {
    private struct Document: Codable {
        let version: Int
        let records: [String: SavedStatistics]
    }

    private let fileURL: URL?
    private let capacity = 32
    private var records: [String: SavedStatistics] = [:]
    private var dirty = false
    private var lastWrite = 0.0
    private(set) var saveFailed = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL = fileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber,
              size.intValue <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return }
        for (id, record) in document.records where record.reading.canBeSaved && !record.fragmentID.isEmpty {
            records[id] = SavedStatistics(fragmentID: record.fragmentID, model: record.model,
                reasoningEffort: record.reasoningEffort, recordedAt: record.recordedAt, reading: record.reading.savedSnapshot)
        }
        trim()
    }

    func record(for threadID: String) -> SavedStatistics? { records[threadID] }

    func capture(threadID: String, fragmentID: String, model: String, reasoningEffort: String?,
                 reading: MeterReading, at date: Date = Date()) {
        guard !threadID.isEmpty, !fragmentID.isEmpty, reading.canBeSaved else { return }
        let snapshot = reading.savedSnapshot
        // Display-time speed decay and later settings changes must not rewrite
        // an already measured fragment or change its original capture time.
        if let old = records[threadID], old.fragmentID == fragmentID, old.reading == snapshot { return }
        records[threadID] = SavedStatistics(fragmentID: fragmentID, model: model,
            reasoningEffort: reasoningEffort, recordedAt: date, reading: snapshot)
        trim(); dirty = true
    }

    func flush(at now: Double, force: Bool = false) {
        guard dirty, let fileURL = fileURL, force || now - lastWrite >= 2 else { return }
        lastWrite = now
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Document(version: 1, records: records))
            try data.write(to: fileURL, options: .atomic)
            dirty = false; saveFailed = false
        } catch { saveFailed = true }
    }

    private func trim() {
        for id in records.keys.sorted(by: { records[$0]!.recordedAt > records[$1]!.recordedAt }).dropFirst(capacity) {
            records.removeValue(forKey: id)
        }
    }
}
