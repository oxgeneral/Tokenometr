import Foundation
import SQLite3

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !condition() { fputs("FAIL: \(description)\n", stderr); exit(1) }
}

let settingsHome = FileManager.default.temporaryDirectory.appendingPathComponent("Tokenometr-settings-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: settingsHome, withIntermediateDirectories: true)
var settingsDB: OpaquePointer?
check(sqlite3_open(settingsHome.appendingPathComponent("state_5.sqlite").path, &settingsDB) == SQLITE_OK,
      "isolated settings fixture opens")
defer { sqlite3_close(settingsDB); try? FileManager.default.removeItem(at: settingsHome) }
func fixtureSQL(_ sql: String) {
    guard sqlite3_exec(settingsDB, sql, nil, nil, nil) == SQLITE_OK else { fatalError("settings fixture SQL failed") }
}
fixtureSQL("CREATE TABLE threads (id TEXT, title TEXT, archived INT, thread_source TEXT, source TEXT, updated_at INT, reasoning_effort TEXT);")
fixtureSQL("INSERT INTO threads VALUES ('desktop','Desktop',0,'user','vscode',100,'xhigh'),('cli','CLI',0,'user','cli',200,'max'),('helper','Helper',0,'agent','appServer',300,'low');")
let locator = ThreadLocator(home: settingsHome)
check(locator.latest()?.id == "desktop" && locator.latest()?.reasoningEffort == "xhigh",
      "selected desktop chat supplies its own effort without CLI or helper metadata")
fixtureSQL("UPDATE threads SET reasoning_effort='high' WHERE id='desktop';")
check(locator.latest()?.reasoningEffort == "high", "saved level refreshes for an unchanged chat ID")
try "model_reasoning_effort = \"max\"\n".write(to: settingsHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
fixtureSQL("UPDATE threads SET reasoning_effort=NULL WHERE id='desktop';")
check(locator.latest()?.reasoningEffort == nil, "missing chat effort cannot invent a global default")
fixtureSQL("UPDATE threads SET reasoning_effort='' WHERE id='desktop';")
check(locator.latest()?.reasoningEffort == nil, "empty stored effort remains unknown")
fixtureSQL("DROP TABLE threads; CREATE TABLE threads (id TEXT,title TEXT,archived INT,thread_source TEXT,source TEXT,updated_at INT); INSERT INTO threads VALUES ('legacy','Legacy',0,'user','vscode',100);")
check(locator.latest()?.id == "legacy" && locator.latest()?.reasoningEffort == nil,
      "older database without effort retains chat discovery")
fixtureSQL("DROP TABLE threads; CREATE TABLE threads (id TEXT,title TEXT,archived INT,source TEXT,updated_at INT,reasoning_effort TEXT); INSERT INTO threads VALUES ('legacy','Legacy',0,'vscode',100,'low');")
check(locator.latest()?.reasoningEffort == "low", "older database without thread source still reads saved effort")
fixtureSQL("DROP TABLE threads; CREATE TABLE threads (id TEXT,title TEXT,archived INT,source TEXT,updated_at INT); INSERT INTO threads VALUES ('legacy','Legacy',0,'vscode',100);")
check(locator.latest()?.id == "legacy" && locator.latest()?.reasoningEffort == nil,
      "oldest supported metadata schema remains readable")

let tokenizer = try Tokenizer(vocabulary: URL(fileURLWithPath: "Resources/o200k_base.tiktoken"))
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/tokenizer-fixtures.json"))) as! [[String: Any]]
for fixture in fixtures {
    let text = fixture["text"] as! String
    check(tokenizer.count(text) == fixture["tokens"] as! Int, "OpenAI tiktoken parity: \(text.prefix(50))")
}

let message: [String: Any] = ["type": "broadcast", "text": "Привет 🙂\nworld", "revision": 9]
let frame = try IPCFramer.encode(message)
var framer = IPCFramer()
var decoded: [[String: Any]] = []
// Exercise length prefixes and UTF-8 sequences split across socket reads.
for byte in frame + frame { decoded += try framer.receive(Data([byte])) }
check(decoded.count == 2, "fragmented and coalesced frames")
check(decoded[0]["text"] as? String == message["text"] as? String, "UTF-8 preserved")
do {
    _ = try framer.receive(Data([255, 255, 255, 255]))
    check(false, "oversized frame must be rejected")
} catch { check(true, "oversized frame rejected") }

check(applyingTextEdits([["at": 2, "deleteCount": 0, "insert": " привет"]], to: "🙂") == "🙂 привет", "JavaScript UTF-16 offsets")
check(applyingTextEdits([["at": 20, "deleteCount": 0, "insert": "x"]], to: "hi") == nil, "bad text offsets rejected")

var meter = LiveMeter()
meter.update(tokens: 10, at: 0)
check(meter.reading(at: 0.2).speed == nil, "one batch cannot establish speed")
meter.update(tokens: 30, at: 1)
check(abs((meter.reading(at: 1).average ?? 0) - 20) < 0.001, "first batch serves as baseline")
meter.finish()
check(meter.reading(at: 30).average == 20 && !meter.reading(at: 30).streaming, "tool delay excluded")

var varying = LiveMeter()
varying.update(tokens: 10, at: 0)
check(varying.reading(at: 0).minimum == nil && varying.reading(at: 0).maximum == nil,
      "single batch cannot establish speed extrema")
varying.update(tokens: 30, at: 1)
check(varying.reading(at: 1).minimum == 20 && varying.reading(at: 1).maximum == 20,
      "first measurable rate establishes both extrema")
varying.update(tokens: 90, at: 2)
varying.update(tokens: 100, at: 3)
check(varying.reading(at: 3).minimum == 20 && varying.reading(at: 3).maximum == 40,
      "min and max retain the range of observed rolling speeds")
check(varying.reading(at: 30).minimum == 20 && varying.reading(at: 30).maximum == 40,
      "idle display refresh cannot dilute extrema")
varying.finish()
varying.update(tokens: 99999, at: 100)
check(varying.reading(at: 100).minimum == 20 && varying.reading(at: 100).maximum == 40,
      "completed fragment freezes extrema")
let statisticsFile = settingsHome.appendingPathComponent("statistics.json")
let store = StatisticsStore(fileURL: statisticsFile)
let captureDate = Date(timeIntervalSince1970: 1000)
store.capture(threadID: "desktop", fragmentID: "measured-fragment", model: "test-model", reasoningEffort: "xhigh",
              reading: varying.reading(at: 100), at: captureDate)
store.flush(at: 10)
let restoredStore = StatisticsStore(fileURL: statisticsFile)
let restored = restoredStore.record(for: "desktop")!
check(restored.reading == varying.reading(at: 100).savedSnapshot && !restored.reading.streaming,
      "disk round trip preserves min, max, average, tokens, duration, and hover samples as a frozen result")
check(restored.model == "test-model" && restored.reasoningEffort == "xhigh" && restored.recordedAt == captureDate,
      "saved measurement retains its capture metadata and timestamp")
check(restoredStore.record(for: "unmeasured-chat") == nil, "saved statistics cannot leak into another chat")
store.capture(threadID: "desktop", fragmentID: "measured-fragment", model: "later-model", reasoningEffort: "low",
              reading: varying.reading(at: 100), at: Date(timeIntervalSince1970: 2000))
check(store.record(for: "desktop")?.recordedAt == captureDate && store.record(for: "desktop")?.model == "test-model",
      "unchanged display refreshes cannot rewrite measurement time or model attribution")
var incomplete = LiveMeter(); incomplete.update(tokens: 7, at: 0)
store.capture(threadID: "desktop", fragmentID: "next-fragment", model: "test-model", reasoningEffort: "high",
              reading: incomplete.reading(at: 0))
check(store.record(for: "desktop") == restored, "a first untimed batch cannot erase the saved fragment")
let oldFile = try Data(contentsOf: statisticsFile)
store.capture(threadID: "second", fragmentID: "second-fragment", model: "test-model", reasoningEffort: nil,
              reading: varying.reading(at: 100), at: Date(timeIntervalSince1970: 2001))
store.flush(at: 11)
let coalescedFile = try Data(contentsOf: statisticsFile)
check(coalescedFile == oldFile, "disk writes are coalesced instead of following every display tick")
store.flush(at: 11, force: true)
check(StatisticsStore(fileURL: statisticsFile).record(for: "second") != nil,
      "shutdown force flush saves the final pending measurement")
let savedContents = try String(contentsOf: statisticsFile, encoding: .utf8)
check(!savedContents.contains("Old history must not enter the speed"),
      "statistics file contains numeric samples and metadata without conversation text")
let bounded = StatisticsStore()
for i in 0...32 {
    bounded.capture(threadID: "chat-\(i)", fragmentID: "fragment-\(i)", model: "test-model", reasoningEffort: nil,
                    reading: varying.reading(at: 100), at: Date(timeIntervalSince1970: Double(i)))
}
check(bounded.record(for: "chat-0") == nil && bounded.record(for: "chat-32") != nil,
      "saved history remains bounded to the most recent 32 chats")
let brokenFile = settingsHome.appendingPathComponent("corrupt-statistics.json")
try "invalid json".write(to: brokenFile, atomically: true, encoding: .utf8)
check(StatisticsStore(fileURL: brokenFile).record(for: "desktop") == nil,
      "invalid saved file starts cleanly without crashing")
let blockedParent = settingsHome.appendingPathComponent("not-a-directory")
try Data().write(to: blockedParent)
let unavailableStore = StatisticsStore(fileURL: blockedParent.appendingPathComponent("statistics.json"))
unavailableStore.capture(threadID: "desktop", fragmentID: "fragment", model: "test-model", reasoningEffort: nil,
                         reading: varying.reading(at: 100))
unavailableStore.flush(at: 10)
check(unavailableStore.saveFailed && unavailableStore.record(for: "desktop") != nil,
      "write failure preserves the in-memory result and reports the saving problem")
let history = varying.reading(at: 100).history
let interval = intervalStatistics(in: history, endingAt: 3)!
check(interval.start == 1 && interval.end == 3 && interval.tokens == 70 && interval.average == 35,
      "hover interval uses actual arrival boundaries and its own token delta")
check(interval.minimum == 20 && interval.maximum == 40,
      "hover extrema describe observed rolling rates inside the selected interval")
check(intervalStatistics(in: Array(history.prefix(1)), endingAt: 0) == nil,
      "one sample cannot invent interval statistics")
check(intervalStatistics(in: history, endingAt: -1) == nil && intervalStatistics(in: history, endingAt: 3, window: 0) == nil,
      "invalid or unobserved intervals produce no statistics")
check(intervalStatistics(in: history, endingAt: 30) == interval,
      "hovering past completed text cannot add idle time")
var longRun = LiveMeter()
for i in 0...1000 { longRun.update(tokens: 7 + i * 10, at: Double(i) * 0.25) }
let retained = longRun.reading(at: 250).history
check(retained.count <= 512 && retained.first!.time >= 189.5,
      "timeline history remains bounded to a minute and its preceding baseline")
check(intervalStatistics(in: retained, endingAt: 250)?.tokens == 80,
      "bounded history preserves the last interval's exact token count")
var brief = LiveMeter()
brief.update(tokens: 1, at: 0)
brief.update(tokens: 10, at: 0.001)
check(brief.reading(at: 0.001).minimum == nil && brief.reading(at: 0.001).maximum == nil,
      "insufficient arrival duration cannot invent min or max")

let accumulator = StreamAccumulator(tokenizer: tokenizer)
let itemPath: [Any] = ["turnHistory", "history", "entitiesByKey", "tail:1", "items", 0]
let snapshot: [String: Any] = ["type": "snapshot", "revision": 0, "conversationState": ["latestModel": "test-model", "latestReasoningEffort": "xhigh", "turns": [["items": [["type": "agentMessage", "id": "old", "text": "Old history must not enter the speed"]]]]]]
check(accumulator.receive(snapshot, at: 0), "snapshot accepted")
check(accumulator.reasoningEffort == "xhigh", "selected reasoning effort comes from stream metadata")
check(accumulator.reading(at: 0) == nil, "history baseline not measured")
check(accumulator.receive(["type": "patches", "baseRevision": 0, "revision": 1,
    "patches": [["op": "add", "path": itemPath, "value": ["type": "agentMessage", "id": "new", "text": ""]]]], at: 0), "message registered")
func textChange(base: Int, revision: Int, at: Int, insert: String, id: String = "new") -> [String: Any] {
    ["type": "patches", "baseRevision": base, "revision": revision, "patches": [],
     "acceptedTextChanges": [["key": ["itemId": id], "target": ["field": "text"],
                               "edits": [["at": at, "deleteCount": 0, "insert": insert]]]]]
}
let first = textChange(base: 1, revision: 2, at: 0, insert: "Hello")
check(accumulator.receive(first, at: 0), "first text delta")
check(accumulator.receive(first, at: 0.5), "duplicate revision ignored")
check(accumulator.receive(textChange(base: 2, revision: 3, at: 5, insert: ", world!"), at: 1), "second text delta")
let reading = accumulator.reading(at: 1)!
check(reading.tokens == 4, "tokenize full text, not independent chunks")
check(abs((reading.average ?? 0) - 3) < 0.001, "measure arrivals independently of server usage")
check(accumulator.receivedChanges == 2, "no double counting duplicate revision")
check(accumulator.receive(["type": "patches", "baseRevision": 3, "revision": 4,
    "patches": [["op": "add", "path": ["turns", 0, "agentMessageCompletedAtMsById", "new"], "value": 999999]]], at: 2), "completion accepted")
check(accumulator.reading(at: 100)?.average == 3, "completion time and tools cannot dilute text throughput")
check(accumulator.reading(at: 100)?.minimum == 3 && accumulator.reading(at: 100)?.maximum == 3,
      "completion preserves observed speed extrema")
let retainedHistory = accumulator.reading(at: 100)?.history
accumulator.refreshMetadata(from: ["latestModel": "test-model", "latestReasoningEffort": NSNull(),
                                  "latestThreadSettings": ["effort": "high"]])
check(accumulator.reasoningEffort == "high" && accumulator.reading(at: 100)?.average == 3 &&
      accumulator.reading(at: 100)?.history == retainedHistory && accumulator.currentRevision == 4,
      "metadata-only refresh updates effort while preserving timing history and revision")
check(accumulator.receive(["type": "patches", "baseRevision": 4, "revision": 5,
    "patches": [["op": "add", "path": ["turns", 1, "items", 0],
                 "value": ["type": "agentMessage", "id": "next", "text": ""]]]], at: 101), "next fragment registered")
check(accumulator.receive(textChange(base: 5, revision: 6, at: 0, insert: "Hello", id: "next"), at: 101), "next fragment begins")
check(accumulator.reading(at: 101)?.minimum == nil && accumulator.reading(at: 101)?.maximum == nil,
      "new fragment cannot inherit previous min or max")
check(!accumulator.receive(textChange(base: 9, revision: 10, at: 13, insert: "bad"), at: 3), "revision gap requests new baseline")
check(accumulator.model == "test-model", "model comes from stream metadata")
check(accumulator.receive(["type": "patches", "baseRevision": 6, "revision": 7,
    "patches": [["op": "replace", "path": ["latestReasoningEffort"], "value": "high"]]], at: 102), "effort selection changes")
check(accumulator.reasoningEffort == "high", "new reasoning selection updates without a new text batch")
check(accumulator.receive(["type": "patches", "baseRevision": 7, "revision": 8,
    "patches": [["op": "replace", "path": ["latestReasoningEffort"], "value": NSNull()]]], at: 103), "effort can be unset")
check(accumulator.reasoningEffort == nil, "missing effort cannot reuse an older selection")
accumulator.reset()
check(accumulator.reasoningEffort == nil && accumulator.reading(at: 103) == nil,
      "new chat or reconnect clears reasoning selection and history")

let metadata = StreamAccumulator(tokenizer: tokenizer)
check(metadata.receive(["type": "snapshot", "revision": 0, "conversationState": [
    "latestReasoningEffort": NSNull(), "latestThreadSettings": ["effort": "xhigh"]]], at: 0), "settings baseline")
check(metadata.reasoningEffort == "xhigh", "thread settings fill an empty stream effort field")
check(metadata.receive(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [[
    "op": "replace", "path": ["latestThreadSettings", "effort"], "value": "low"]]], at: 1), "settings effort patch")
check(metadata.reasoningEffort == "low", "nested effort updates without a new answer")
metadata.refreshMetadata(from: ["latestCollaborationMode": ["settings": ["reasoning_effort": "medium"]]])
check(metadata.reasoningEffort == "medium", "collaboration settings also carry the selected level")
metadata.refreshMetadata(from: ["latestReasoningEffort": "high", "latestThreadSettings": ["effort": "low"]])
check(metadata.reasoningEffort == "high", "explicit live effort takes precedence over fallback metadata")

// A tool can finish while an assistant message is still streaming.
let overlapping = StreamAccumulator(tokenizer: tokenizer)
check(overlapping.receive(["type": "snapshot", "revision": 0, "conversationState": ["turns": []]], at: 0), "overlap baseline")
check(overlapping.receive(["type": "patches", "baseRevision": 0, "revision": 1,
    "patches": [["op": "add", "path": itemPath, "value": ["type": "agentMessage", "id": "new", "text": ""]]]], at: 0), "overlap item")
check(overlapping.receive(textChange(base: 1, revision: 2, at: 0, insert: "Hello"), at: 0), "overlap first delta")
check(overlapping.receive(textChange(base: 2, revision: 3, at: 5, insert: ", world!"), at: 1), "overlap next delta")
_ = overlapping.reading(at: 1)
check(overlapping.receive(["type": "patches", "baseRevision": 3, "revision": 4,
    "patches": [["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "tail:1", "items", 1, "status"], "value": "completed"]]], at: 1.1), "unrelated tool completes")
check(overlapping.receive(textChange(base: 4, revision: 5, at: 13, insert: " More tokens arrive."), at: 2), "text continues after tool")
check(overlapping.reading(at: 2)?.tokens == tokenizer.count("Hello, world! More tokens arrive."), "tool completion must not freeze text counter")

// Attaching halfway through a message must not invent timing for the first
// newly observed batch or include already displayed history in its throughput.
let midway = StreamAccumulator(tokenizer: tokenizer)
check(midway.receive(["type": "snapshot", "revision": 0, "conversationState": ["turns": [["items": [["type": "agentMessage", "id": "new", "text": "Hello"]]]]]], at: 0), "midstream baseline")
check(midway.receive(textChange(base: 0, revision: 1, at: 5, insert: ", world!"), at: 1), "midstream first observation")
check(midway.reading(at: 1)?.average == nil, "first midstream batch has no measurable duration")
check(midway.receive(textChange(base: 1, revision: 2, at: 13, insert: " More."), at: 2), "midstream second observation")
check(midway.reading(at: 2)?.average == Double(tokenizer.count("Hello, world! More.") - tokenizer.count("Hello, world!")), "midstream history is excluded from speed")

let cleared = StreamAccumulator(tokenizer: tokenizer)
check(cleared.receive(["type": "snapshot", "revision": 0, "conversationState": ["turns": [["items": [["type": "agentMessage", "id": "new", "text": "Hello"]]]]]], at: 0), "text replacement baseline")
check(cleared.receive(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [],
    "acceptedTextChanges": [["key": ["itemId": "new"], "target": ["field": "text"],
      "edits": [["at": 0, "deleteCount": 5, "insert": ""]]]]], at: 1), "empty replacement accepted")
check(cleared.receive(textChange(base: 1, revision: 2, at: 0, insert: "Goodbye"), at: 2), "text after empty replacement accepted")
check(cleared.reading(at: 2)?.tokens == tokenizer.count("Goodbye"), "erased text cannot remain in the counter")

let rapid = StreamAccumulator(tokenizer: tokenizer)
var retainedBeforeNext: MeterReading?
var retainedMeasurementID: String?
rapid.onFragmentReplaced = { id, reading in retainedMeasurementID = id; retainedBeforeNext = reading }
_ = rapid.receive(["type": "snapshot", "revision": 0, "conversationState": ["turns": []]], at: 0)
_ = rapid.receive(["type": "patches", "baseRevision": 0, "revision": 1,
    "patches": [["op": "add", "path": itemPath, "value": ["type": "agentMessage", "id": "new", "text": ""]]]], at: 0)
_ = rapid.receive(textChange(base: 1, revision: 2, at: 0, insert: "Hello"), at: 0)
_ = rapid.receive(textChange(base: 2, revision: 3, at: 5, insert: ", world!"), at: 1)
_ = rapid.receive(["type": "patches", "baseRevision": 3, "revision": 4,
    "patches": [["op": "add", "path": ["turns", 1, "items", 0],
                 "value": ["type": "agentMessage", "id": "next", "text": ""]]]], at: 1.1)
_ = rapid.receive(textChange(base: 4, revision: 5, at: 0, insert: "Hello", id: "next"), at: 1.2)
check(retainedBeforeNext?.tokens == 4 && retainedBeforeNext?.average == 3 && retainedBeforeNext?.history.count == 2,
      "next message archives its predecessor even before a display tick has measured the last batch")
check(retainedMeasurementID != rapid.measurementID && rapid.reading(at: 1.2)?.average == nil,
      "new fragment gets independent timing and graph identity while its predecessor remains recoverable")

check(WebSocketFramer.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC WebSocket upgrade challenge")
func serverFrame(_ text: String, opcode: UInt8 = 1, final: Bool = true) -> Data {
    let body = Data(text.utf8)
    var data = Data([(final ? 0x80 : 0) | opcode])
    if body.count < 126 { data.append(UInt8(body.count)) }
    else { data.append(contentsOf: [126, UInt8(body.count >> 8), UInt8(body.count & 255)]) }
    data.append(body); return data
}
var ws = WebSocketFramer()
var wsPackets: [WebSocketPacket] = []
let wsText = String(repeating: "Привет🙂", count: 30)
let wsFrames = serverFrame(wsText, final: false) + serverFrame("ping", opcode: 9) + serverFrame("end", opcode: 0)
for byte in wsFrames { wsPackets += try ws.receive(Data([byte])) }
check(wsPackets.count == 2 && wsPackets[0].opcode == 9, "WebSocket ping can interleave fragmented text")
check(String(data: wsPackets[1].data, encoding: .utf8) == wsText + "end", "fragmented WebSocket UTF-8 and extended length preserve public text")
let masked = Array(WebSocketFramer.encode(Data("hello".utf8)))
check(masked[1] & 128 != 0, "CLI client WebSocket frames are masked")
check(String(bytes: masked[6...].enumerated().map { $0.element ^ masked[2 + $0.offset % 4] }, encoding: .utf8) == "hello", "client frame mask round trip")
do { _ = try ws.receive(Data([0x81, 127, 0, 0, 0, 0, 1, 0, 0, 0])); check(false, "oversized WebSocket frame rejected") }
catch { check(true, "oversized WebSocket frame rejected") }
var badWS = WebSocketFramer()
do { _ = try badWS.receive(Data([0x09, 0])); check(false, "fragmented control frame rejected") }
catch { check(true, "fragmented control frame rejected") }

let cliStream = CLIStream(threadID: "cli", tokenizer: tokenizer)
cliStream.metadata(["model": "cli-model", "reasoningEffort": "xhigh"])
func cliDelta(_ delta: String, item: String = "answer", turn: String = "turn", thread: String = "cli") -> [String: Any] {
    ["threadId": thread, "turnId": turn, "itemId": item, "delta": delta]
}
check(!cliStream.receive("item/agentMessage/delta", cliDelta("wrong", thread: "desktop"), at: 0), "foreign CLI thread cannot contribute text")
check(!cliStream.receive("item/reasoning/textDelta", cliDelta("hidden"), at: 0), "hidden CLI reasoning excluded")
check(!cliStream.receive("item/commandExecution/outputDelta", cliDelta("tools"), at: 0), "CLI tool output excluded")
check(!cliStream.receive("thread/tokenUsage/updated", ["threadId": "cli", "outputTokens": 999999], at: 0), "CLI server usage excluded")
check(cliStream.reading(at: 1) == nil, "stored CLI messages and usage cannot invent a measurement")
check(cliStream.receive("item/agentMessage/delta", cliDelta("Hello"), at: 10), "live CLI assistant delta accepted")
check(cliStream.reading(at: 10)?.average == nil, "first CLI text batch is an untimed baseline")
_ = cliStream.receive("item/agentMessage/delta", cliDelta(", world!"), at: 11)
let cliReading = cliStream.reading(at: 11)!
check(cliReading.tokens == tokenizer.count("Hello, world!") && cliReading.average == 3, "CLI uses own arrival clock and BPE over the whole message")
check(cliReading.minimum == 3 && cliReading.maximum == 3 && cliReading.history.count == 2, "CLI exposes extrema and real interval samples")
_ = cliStream.receive("thread/settings/updated", ["threadId": "cli", "threadSettings": ["model": "cli-model", "effort": "high"]], at: 12)
check(cliStream.reasoningEffort == "high" && cliStream.reading(at: 12)?.history == cliReading.history, "CLI level changes do not reset the graph")
_ = cliStream.receive("item/completed", ["threadId": "cli", "turnId": "turn", "item": ["id": "answer", "type": "agentMessage", "text": "unobserved final payload"]], at: 14)
check(cliStream.reading(at: 30)?.tokens == cliReading.tokens && cliStream.reading(at: 30)?.streaming == false, "CLI completion freezes deltas without counting final payload twice")
check(!cliStream.receive("item/agentMessage/delta", cliDelta("late"), at: 31), "late deltas cannot reopen a completed CLI item")
var replacedCLI: MeterReading?
cliStream.onFragmentReplaced = { _, reading in replacedCLI = reading }
_ = cliStream.receive("item/agentMessage/delta", cliDelta("Новый 🙂", item: "second", turn: "second-turn"), at: 32)
check(replacedCLI?.tokens == cliReading.tokens && replacedCLI?.average == 3, "next CLI message archives the previous timed fragment")
check(cliStream.reading(at: 32)?.average == nil, "new CLI message has independent timing")
_ = cliStream.receive("item/agentMessage/delta", cliDelta(" ответ", item: "second", turn: "second-turn"), at: 33)
_ = cliStream.receive("turn/completed", ["threadId": "cli", "turn": ["id": "second-turn", "status": "completed"]], at: 34)
check(cliStream.reading(at: 34)?.tokens == tokenizer.count("Новый 🙂 ответ") && cliStream.reading(at: 34)?.streaming == false, "CLI Unicode and turn completion preserve measured text")

let start = monotonicTime()
let largeText = String(repeating: "Привет, world! let x = 42; 🙂\n", count: 500)
check(tokenizer.count(largeText) > 0, "long mixed text")
print("PASS: \(assertions) checks; tokenizer sample \(Int((monotonicTime() - start) * 1000)) ms")
