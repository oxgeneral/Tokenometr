import Foundation

struct MeterSample: Equatable, Codable {
    let time: Double
    let tokens: Int
    let speed: Double?
}

struct IntervalStatistics: Equatable {
    let start: Double
    let end: Double
    let tokens: Int
    let average: Double
    let minimum: Double
    let maximum: Double
    var duration: Double { end - start }
}

/// Uses actual arrival boundaries, rather than assigning token counts to times
/// when no text was observed. Times are relative to the fragment's first batch.
func intervalStatistics(in samples: [MeterSample], endingAt time: Double,
                        window: Double = 2) -> IntervalStatistics? {
    guard window > 0, time.isFinite,
          let end = samples.lastIndex(where: { $0.time <= time }) else { return nil }
    let cutoff = samples[end].time - window
    let start = samples[...end].lastIndex(where: { $0.time <= cutoff }) ?? samples.startIndex
    let duration = samples[end].time - samples[start].time
    guard end > start, duration >= 0.05 else { return nil }
    let speeds = samples[start...end].compactMap(\.speed)
    guard let minimum = speeds.min(), let maximum = speeds.max() else { return nil }
    let tokens = max(0, samples[end].tokens - samples[start].tokens)
    return IntervalStatistics(start: samples[start].time, end: samples[end].time,
        tokens: tokens, average: Double(tokens) / duration, minimum: minimum, maximum: maximum)
}
