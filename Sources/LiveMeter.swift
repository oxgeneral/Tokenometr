import Foundation

struct MeterReading: Equatable, Codable {
    let tokens: Int
    let speed: Double?
    let average: Double?
    let minimum: Double?
    let maximum: Double?
    let duration: Double
    let streaming: Bool
    var history: [MeterSample] = []

    var savedSnapshot: MeterReading {
        MeterReading(tokens: tokens, speed: average, average: average, minimum: minimum,
                     maximum: maximum, duration: duration, streaming: false, history: history)
    }

    var canBeSaved: Bool {
        guard tokens >= 0, duration.isFinite, duration >= 0.05,
              let average = average, average.isFinite, average >= 0, history.count <= 512 else { return false }
        let rates = [speed, minimum, maximum].compactMap { $0 }
        return rates.allSatisfy { $0.isFinite && $0 >= 0 } && history.allSatisfy {
            $0.time.isFinite && $0.time >= 0 && $0.tokens >= 0 && ($0.speed.map { $0.isFinite && $0 >= 0 } ?? true)
        }
    }
}

/// Measures text arrivals using a monotonic clock. Each sample is the token count
/// of the entire accumulated message, so BPE merges across chunks are preserved.
struct LiveMeter {
    private var samples: [(time: Double, tokens: Int)] = []
    private var firstTime: Double?
    private var firstTokens = 0
    private var lastTime = 0.0
    private var tokens = 0
    private var finished = false
    private var minimum: Double?
    private var maximum: Double?
    private var history: [MeterSample] = []

    mutating func update(tokens count: Int, at time: Double) {
        guard count >= 0, !finished else { return }
        if firstTime == nil {
            firstTime = time
            firstTokens = count
        }
        tokens = count
        lastTime = time
        samples.append((time, count))
        // Retain one sample immediately before the rolling window.
        while samples.count > 2 && samples[1].time < time - 2 { samples.removeFirst() }
        // Record only observed text arrivals. Display refreshes and waiting for
        // tools must never lower the minimum or change a completed fragment.
        let speed = windowSpeed(at: time)
        if let speed = speed {
            minimum = min(minimum ?? speed, speed)
            maximum = max(maximum ?? speed, speed)
        }
        let elapsed = max(0, time - (firstTime ?? time))
        history.append(MeterSample(time: elapsed, tokens: count, speed: speed))
        // A minute of arrival samples plus its preceding baseline, bounded even
        // if a desktop build publishes unusually frequent completion updates.
        while history.count > 2 && history[1].time < elapsed - 60 { history.removeFirst() }
        if history.count > 512 { history.removeFirst(history.count - 512) }
    }

    mutating func finish() { finished = true }

    func reading(at now: Double) -> MeterReading {
        let duration = max(0, lastTime - (firstTime ?? lastTime))
        let average = duration >= 0.05 ? Double(max(0, tokens - firstTokens)) / duration : nil
        let live = !finished && firstTime != nil && now - lastTime < 1.5
        let end = live ? now : lastTime
        return MeterReading(tokens: tokens, speed: live ? windowSpeed(at: end) : average,
                            average: average, minimum: minimum, maximum: maximum,
                            duration: duration, streaming: live, history: history)
    }

    private func windowSpeed(at end: Double) -> Double? {
        let baseline = samples.last(where: { $0.time <= end - 2 }) ?? samples.first
        let windowDuration = end - (baseline?.time ?? end)
        return samples.count > 1 && windowDuration >= 0.05
            ? Double(max(0, tokens - (baseline?.tokens ?? tokens))) / windowDuration : nil
    }
}

func monotonicTime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

/// IPC text offsets follow JavaScript's UTF-16 convention, not Swift Characters.
func applyingTextEdits(_ edits: [[String: Any]], to text: String) -> String? {
    let result = NSMutableString(string: text)
    for edit in edits.sorted(by: { ($0["at"] as? Int ?? 0) > ($1["at"] as? Int ?? 0) }) {
        guard let at = edit["at"] as? Int, let deleted = edit["deleteCount"] as? Int,
              let inserted = edit["insert"] as? String,
              at >= 0, deleted >= 0, at <= result.length, deleted <= result.length - at else { return nil }
        result.replaceCharacters(in: NSRange(location: at, length: deleted), with: inserted)
    }
    return result as String
}
