import Foundation

/// OpenAI's published o200k_base vocabulary and byte pair encoding.
/// Codex's exact private model tokenizer is not exposed; UI values use ≈.
final class Tokenizer {
    private var ranks: [Data: Int] = [:]
    private let regex: NSRegularExpression

    init(vocabulary: URL) throws {
        let patterns = [
            #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
            #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
            #"\p{N}{1,3}"#, #" ?[^\s\p{L}\p{N}]+[\r\n/]*"#,
            #"\s*[\r\n]+"#, #"\s+(?!\S)"#, #"\s+"#
        ]
        regex = try NSRegularExpression(pattern: patterns.joined(separator: "|"))
        let vocabularyText = try String(contentsOf: vocabulary, encoding: .utf8)
        ranks.reserveCapacity(200000)
        for line in vocabularyText.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let bytes = Data(base64Encoded: String(fields[0])),
                  let rank = Int(fields[1]) else { continue }
            ranks[bytes] = rank
        }
        guard ranks.count == 199998 else { throw CocoaError(.fileReadCorruptFile) }
    }

    func count(_ text: String) -> Int {
        let source = text as NSString
        var total = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match = match else { return }
            let bytes = Data(source.substring(with: match.range).utf8)
            total += self.pieceCount(bytes)
        }
        return total
    }

    private struct Pair { let rank: Int; let left: Int; let right: Int }

    private func pieceCount(_ bytes: Data) -> Int {
        if ranks[bytes] != nil { return 1 }
        guard bytes.count > 1 else { return bytes.count }
        // Linked segments and a minimum heap avoid quadratic behavior for long
        // punctuation, URLs, and other unusually large regex pieces.
        let n = bytes.count
        var next = Array(1...n)
        var previous = Array(-1..<(n - 1))
        var end = Array(1...n)
        var alive = [Bool](repeating: true, count: n)
        var heap: [Pair] = []
        func precedes(_ a: Pair, _ b: Pair) -> Bool {
            a.rank == b.rank ? a.left < b.left : a.rank < b.rank
        }
        func push(_ pair: Pair) {
            heap.append(pair)
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if !precedes(heap[i], heap[p]) { break }
                heap.swapAt(i, p); i = p
            }
        }
        func pop() -> Pair? {
            guard !heap.isEmpty else { return nil }
            let result = heap[0], last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while i * 2 + 1 < heap.count {
                    var child = i * 2 + 1
                    if child + 1 < heap.count && precedes(heap[child + 1], heap[child]) { child += 1 }
                    if !precedes(heap[child], heap[i]) { break }
                    heap.swapAt(i, child); i = child
                }
            }
            return result
        }
        func addPair(_ left: Int) {
            guard left >= 0, left < n, alive[left], next[left] < n else { return }
            let right = next[left]
            if let rank = ranks[bytes.subdata(in: left..<end[right])] {
                push(Pair(rank: rank, left: left, right: right))
            }
        }
        for i in 0..<(n - 1) { addPair(i) }
        var count = n
        while let pair = pop() {
            let l = pair.left, r = pair.right
            guard alive[l], alive[r], next[l] == r,
                  ranks[bytes.subdata(in: l..<end[r])] == pair.rank else { continue }
            alive[r] = false
            end[l] = end[r]; next[l] = next[r]
            if next[r] < n { previous[next[r]] = l }
            count -= 1
            addPair(previous[l]); addPair(l)
        }
        return count
    }
}
