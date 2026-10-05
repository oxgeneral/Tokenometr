#!/usr/bin/env python3
"""Exercise the native monitor against an isolated local desktop IPC fixture.

Only Python's standard library is needed for this development test. The running
Codex, its database, and the installed Tokenometr are never modified here.
"""
import json
import os
from pathlib import Path
import queue
import socket
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = ROOT / "dist/Tokenometr.app/Contents/MacOS/Tokenometr"
checks = []
reports = []


def check(condition, label):
    if not condition:
        raise AssertionError(label)
    checks.append(label)


def encode(message):
    body = json.dumps(message, ensure_ascii=False).encode()
    return struct.pack("<I", len(body)) + body


def exact(conn, length):
    result = b""
    while len(result) < length:
        chunk = conn.recv(length - len(result))
        if not chunk:
            raise EOFError("native monitor disconnected unexpectedly")
        result += chunk
    return result


def receive(conn):
    message = json.loads(exact(conn, struct.unpack("<I", exact(conn, 4))[0]))
    if message.get("type") == "broadcast":
        check(message.get("method") == "thread-stream-following-changed",
              "monitor sends only passive subscription broadcasts")
    return message


def wait_message(conn, predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        conn.settimeout(max(0.01, deadline - time.monotonic()))
        message = receive(conn)
        if predicate(message):
            conn.settimeout(8)
            return message
    raise AssertionError("expected IPC message not received")


def handshake(server, client, thread="desktop"):
    conn, _ = server.accept()
    conn.settimeout(8)
    request = receive(conn)
    check(request.get("method") == "initialize", "native connection initializes")
    frame = encode({"type": "response", "method": "initialize",
                    "requestId": request["requestId"], "result": {"clientId": client}})
    # Deliberately fragment both the length prefix and JSON body.
    conn.sendall(frame[:2])
    conn.sendall(frame[2:7])
    conn.sendall(frame[7:])
    follow = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
    check(follow["params"]["conversationId"] == thread,
          "CLI and hidden helper chats cannot divert the desktop monitor")
    return conn


def broadcast(conn, method, params, owner="window-1", targets=None):
    message = {"type": "broadcast", "method": method,
               "sourceClientId": owner, "version": 1, "params": params}
    if targets is not None:
        message["targetClientIds"] = targets
    conn.sendall(encode(message))


def stream(conn, change, client="fixture-1", thread="desktop", host="local", owner="window-1"):
    conn.sendall(encode({"type": "broadcast", "method": "thread-stream-state-changed",
                        "sourceClientId": owner, "version": 11, "targetClientIds": [client],
                        "params": {"conversationId": thread, "hostId": host, "change": change}}))


def snapshot(revision, text="Hello", model="fixture-model", item="answer", effort="xhigh"):
    return {"type": "snapshot", "revision": revision, "conversationState": {
        "latestModel": model, "latestReasoningEffort": effort, "turnHistory": {"history": {"entitiesByKey": {
            "tail:1": {"status": "inProgress", "items": [
                {"type": "agentMessage", "id": item, "text": text}]}}}}}}


def patch(base, revision, edits=None, patches=None):
    return {"type": "patches", "baseRevision": base, "revision": revision,
            "acceptedTextChanges": edits or [], "patches": patches or []}


def edit(offset, insert, item="answer"):
    return {"key": {"itemId": item}, "target": {"field": "text"},
            "edits": [{"at": offset, "deleteCount": 0, "insert": insert}]}


def wait_report(predicate, since):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            arrived, report = output.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty:
            break
        if arrived >= since and predicate(report):
            return report
    raise AssertionError(f"expected numeric monitor state not observed; last state: {reports[-1:]}")


with tempfile.TemporaryDirectory(prefix="tm-", dir="/tmp") as directory:
    home = Path(directory)
    (home / "ipc").mkdir()
    db = sqlite3.connect(home / "state_5.sqlite")
    db.execute("CREATE TABLE threads (id TEXT, title TEXT, archived INT, thread_source TEXT, source TEXT, updated_at INT, reasoning_effort TEXT)")
    db.executemany("INSERT INTO threads (id, title, archived, thread_source, source, updated_at) VALUES (?, ?, 0, ?, ?, ?)", [
        ("desktop", "Test desktop", "user", "vscode", 100),
        ("cli", "Test CLI", "user", "cli", 200),
        ("helper", "Test helper", "agent", "appServer", 300)])
    db.execute("UPDATE threads SET reasoning_effort='xhigh' WHERE id='desktop'")
    db.commit()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(home / "ipc/ipc.sock"))
    server.listen(2)
    server.settimeout(8)
    output = queue.Queue()
    statistics_file = home / "tokenometr-statistics.json"

    def start_monitor():
        return subprocess.Popen([str(EXECUTABLE), "--diagnose", "--duration", "180",
                                 "--statistics-file", str(statistics_file)],
                               env={**os.environ, "CODEX_HOME": str(home)},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    process = start_monitor()

    def collect():
        for line in process.stdout:
            report = json.loads(line)
            reports.append(report)
            output.put((time.monotonic(), report))

    collector = threading.Thread(target=collect, daemon=True)
    collector.start()
    conn = None
    try:
        conn = handshake(server, "fixture-1")
        mark = time.monotonic()
        stream(conn, snapshot(0, effort=None))
        baseline = wait_report(lambda r: r["connected"] and r["model"] == "fixture-model", mark)
        check(baseline["tokens"] == 0 and baseline["averageTokensPerSecond"] is None,
              "snapshot history cannot produce a speed reading")
        check(baseline["reasoningEffort"] == "xhigh",
              "empty IPC effort uses this chat's saved level instead of a global default")
        mark = time.monotonic()
        db.execute("UPDATE threads SET reasoning_effort='high' WHERE id='desktop'")
        db.commit()
        selected = wait_report(lambda r: r["reasoningEffort"] == "high", mark)
        check(selected["tokens"] == 0 and selected["historySamples"] == 0,
              "saved reasoning selection refreshes in the same chat without creating text samples")

        # Wrong host, conversation, or target must not contaminate this stream.
        stream(conn, snapshot(500, model="wrong-host"), host="remote")
        stream(conn, snapshot(500, model="wrong-thread"), thread="other")
        stream(conn, snapshot(500, model="wrong-target"), client="other-client")
        stream(conn, patch(0, 1, patches=[
            {"op": "replace", "path": ["latestTokenUsage"], "value": {"outputTokens": 9999999}},
            {"op": "replace", "path": ["latestReasoningEffort"], "value": "high"}]))
        path = ["turnHistory", "history", "entitiesByKey", "tail:1", "items"]
        stream(conn, patch(1, 2, edits=[edit(0, "tool output", "tool"), edit(0, "hidden reasoning", "reasoning")], patches=[
            {"op": "add", "path": path + [1], "value": {"id": "tool", "type": "commandExecution", "text": ""}},
            {"op": "add", "path": path + [2], "value": {"id": "reasoning", "type": "reasoning", "text": ""}}]))
        conn.sendall(encode({"type": "client-discovery-request", "requestId": "discovery"}) +
                     encode({"type": "request", "method": "turn/start", "requestId": "control"}))
        discovery = wait_message(conn, lambda m: m.get("requestId") == "discovery")
        refusal = wait_message(conn, lambda m: m.get("requestId") == "control")
        check(discovery["response"]["canHandle"] is False, "monitor does not advertise chat control")
        check(refusal["resultType"] == "error" and refusal["error"] == "read-only-monitor",
              "incoming control request is refused")
        unchanged = wait_report(lambda r: r["model"] == "fixture-model" and r["reasoningEffort"] == "high", mark)
        check(unchanged["tokens"] == 0 and unchanged["textChanges"] == 0,
              "usage counters, tools, reasoning, and foreign events are excluded")
        check(unchanged["historySamples"] == 0, "reasoning selection update cannot create timeline samples")

        mark = time.monotonic()
        stream(conn, patch(2, 3, edits=[edit(5, ", world!")]))
        first = wait_report(lambda r: r["tokens"] == 4, mark)
        check(first["averageTokensPerSecond"] is None, "first midstream batch has no invented timing")
        check(first["minimumTokensPerSecond"] is None and first["maximumTokensPerSecond"] is None,
              "first native sample has no invented extrema")
        time.sleep(0.8)
        mark = time.monotonic()
        second_change = patch(3, 4, edits=[edit(13, " Hello, world!")])
        stream(conn, second_change)
        second = wait_report(lambda r: r["tokens"] == 8 and r["streaming"], mark)
        check(second["durationSeconds"] >= 0.8 and
              abs(second["averageTokensPerSecond"] * second["durationSeconds"] - 4) < 0.001,
              "native throughput uses independently counted tokens and arrival time")
        check(abs(second["minimumTokensPerSecond"] - second["averageTokensPerSecond"]) < 0.001 and
              abs(second["maximumTokensPerSecond"] - second["averageTokensPerSecond"]) < 0.001,
              "native min and max begin at the first independently timed speed")
        check(second["historySamples"] >= 2, "native text arrivals provide timed samples for hover inspection")

        # The desktop window may lose its followers without closing this socket.
        # It asks surviving clients to announce their subscription again.
        broadcast(conn, "thread-stream-following-status-requested",
                  {"conversationId": "desktop", "hostId": "local"})
        reannounced = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        check(reannounced["params"]["following"] is True and
              reannounced.get("targetClientIds") == ["window-1"],
              "window follower reset restores a targeted subscription without socket reconnect")
        mark = time.monotonic()
        stream(conn, snapshot(4, "Hello, world! Hello, world!", effort="low"))
        preserved = wait_report(lambda r: r["tokens"] == 8, mark)
        check(preserved["averageTokensPerSecond"] == second["averageTokensPerSecond"] and
              preserved["historySamples"] == second["historySamples"],
              "repeat baseline after subscription renewal preserves measured speed and hover history")
        check(preserved["reasoningEffort"] == "low",
              "same-revision snapshot refreshes live effort and overrides stored fallback without resetting speed")
        broadcast(conn, "client-status-changed", {"clientId": "other-window", "status": "connected"},
                  owner="other-window")
        targeted = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        check(targeted.get("targetClientIds") == ["other-window"],
              "new desktop client receives the current passive subscription")
        broadcast(conn, "client-status-changed", {"clientId": "other-window", "status": "disconnected"},
                  owner="other-window")
        mark = time.monotonic()
        stream(conn, second_change)
        repeated = wait_report(lambda r: r["tokens"] == 8, mark)
        check(repeated["textChanges"] == 2, "duplicate revision never counts twice")

        stream(conn, patch(4, 5, patches=[
            {"op": "replace", "path": path + [1, "status"], "value": "completed"}]))
        mark = time.monotonic()
        stream(conn, patch(5, 6, edits=[edit(27, " Hello, world!")]))
        continuing = wait_report(lambda r: r["tokens"] == 12, mark)
        check(continuing["textChanges"] == 3, "tool completion cannot freeze an overlapping answer")
        mark = time.monotonic()
        stream(conn, patch(6, 7, patches=[{"op": "add", "path": [
            "turnHistory", "history", "entitiesByKey", "tail:1", "agentMessageCompletedAtMsById", "answer"], "value": 1}]))
        completed = wait_report(lambda r: r["tokens"] == 12 and not r["streaming"], mark)
        check(abs(completed["tokensPerSecond"] - completed["averageTokensPerSecond"]) < 0.001,
              "completion retains measured average without tool waiting time")
        check(completed["minimumTokensPerSecond"] == continuing["minimumTokensPerSecond"] and
              completed["maximumTokensPerSecond"] == continuing["maximumTokensPerSecond"],
              "completion preserves min and max while display speed changes")
        mark = time.monotonic()
        stream(conn, snapshot(8, "Hello, world! Hello, world! Hello, world!"))
        finished_snapshot = wait_report(lambda r: r["tokens"] == 12 and r.get("usingSavedReading"), mark)
        check(finished_snapshot["averageTokensPerSecond"] == completed["averageTokensPerSecond"] and
              finished_snapshot["historySamples"] == completed["historySamples"],
              "completion snapshot with a new revision cannot erase measured statistics or graph")

        # Quiet connections renew their lease too: an owner can silently reload.
        def unrelated_join():
            time.sleep(12)
            broadcast(conn, "client-status-changed", {"clientId": "lease-noise", "status": "connected"},
                      owner="lease-noise")

        threading.Thread(target=unrelated_join, daemon=True).start()
        renewed = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed" and
                               not m.get("targetClientIds"),
                               timeout=35)
        check(renewed["params"]["following"] is True,
              "quiet socket repairs a lost follower even when unrelated clients join")
        mark = time.monotonic()
        stream(conn, snapshot(8, "Hello, world! Hello, world! Hello, world!"))
        stable = wait_report(lambda r: r["tokens"] == 12, mark)
        check(stable["averageTokensPerSecond"] == completed["averageTokensPerSecond"],
              "quiet subscription refresh cannot erase the retained result")

        mark = time.monotonic()
        stream(conn, patch(8, 9, patches=[{"op": "add", "path": path + [3],
                                        "value": {"type": "agentMessage", "id": "next", "text": ""}}]))
        stream(conn, patch(9, 10, edits=[edit(0, "Hello", "next")]))
        starting = wait_report(lambda r: r.get("observedTokens") == 1, mark)
        check(starting["usingSavedReading"] and starting["tokens"] == 12 and
              starting["minimumTokensPerSecond"] == completed["minimumTokensPerSecond"] and
              starting["maximumTokensPerSecond"] == completed["maximumTokensPerSecond"] and
              starting["historySamples"] == completed["historySamples"],
              "first batch of the next message retains the preceding measurable fragment")
        time.sleep(0.8)
        mark = time.monotonic()
        stream(conn, patch(10, 11, edits=[edit(5, ", world!", "next")]))
        next_reading = wait_report(lambda r: r["tokens"] == 4 and not r["usingSavedReading"], mark)
        check(next_reading["averageTokensPerSecond"] is not None and next_reading["historySamples"] == 2,
              "new measurable fragment replaces saved statistics with its own arrival history")

        mark = time.monotonic()
        stream(conn, patch(20, 21, edits=[edit(39, "missing event")]))
        resubscription = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        check(resubscription["params"]["following"] is True, "revision gap requests a new snapshot")
        stream(conn, snapshot(21, "History after gap"))
        repaired = wait_report(lambda r: r.get("usingSavedReading"), mark)
        check(repaired["averageTokensPerSecond"] == next_reading["averageTokensPerSecond"] and
              repaired["observedTokens"] == 0,
              "gap recovery shows the saved result while resetting live throughput")
        check(repaired["minimumTokensPerSecond"] == next_reading["minimumTokensPerSecond"] and
              repaired["maximumTokensPerSecond"] == next_reading["maximumTokensPerSecond"],
              "resynchronization retains saved extrema")
        stream(conn, patch(21, 22, edits=[edit(99999, "bad offset")]))
        resubscription = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        check(resubscription["params"]["following"] is True, "invalid UTF-16 edit requests a fresh baseline")
        stream(conn, snapshot(22))

        mark = time.monotonic()
        conn.close()
        conn = None
        offline = wait_report(lambda r: not r["connected"], mark)
        check(offline["tokens"] == 4 and offline["usingSavedReading"] and
              offline["averageTokensPerSecond"] == next_reading["averageTokensPerSecond"] and not offline["streaming"],
              "connection loss retains frozen statistics instead of presenting a live stale reading")
        conn = handshake(server, "fixture-2")
        stream(conn, snapshot(0, "", "reconnected"), client="fixture-2")
        mark = time.monotonic()
        stream(conn, patch(0, 1, edits=[edit(0, "Привет 🙂")]), client="fixture-2")
        russian = wait_report(lambda r: r["model"] == "reconnected" and r.get("observedTokens") == 3, mark)
        check(russian["observedAverageTokensPerSecond"] is None and russian["usingSavedReading"],
              "reconnection starts its own baseline while the previous result remains visible")
        time.sleep(0.8)
        mark = time.monotonic()
        stream(conn, patch(1, 2, edits=[edit(9, " Hello, world!")]), client="fixture-2")
        utf16 = wait_report(lambda r: r["tokens"] == 7, mark)
        check(abs(utf16["averageTokensPerSecond"] * utf16["durationSeconds"] - 4) < 0.001,
              "Unicode and UTF-16 text edits survive real socket framing")

        mark = time.monotonic()
        broadcast(conn, "client-status-changed", {"clientId": "window-1", "status": "disconnected"})
        restored = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        check(restored["params"]["following"] is True, "owner loss triggers passive resubscription")
        absent = wait_report(lambda r: r.get("usingSavedReading"), mark)
        check(absent["connected"] and absent["observedTokens"] == 0 and
              absent["averageTokensPerSecond"] == utf16["averageTokensPerSecond"],
              "owner loss resets live counters but retains the last measured statistics")
        broadcast(conn, "client-status-changed", {"clientId": "window-2", "status": "connected"}, owner="window-2")
        wait_message(conn, lambda m: m.get("targetClientIds") == ["window-2"])
        # A new owner starts its revision counter again, often below the old one.
        stream(conn, snapshot(0, "", "new-window"), client="fixture-2", owner="window-2")
        mark = time.monotonic()
        stream(conn, patch(0, 1, edits=[edit(0, "Hello")]), client="fixture-2", owner="window-2")
        replaced = wait_report(lambda r: r["model"] == "new-window" and r.get("observedTokens") == 1, mark)
        check(replaced["observedAverageTokensPerSecond"] is None and replaced["usingSavedReading"],
              "new window accepts lower revisions and starts a fresh arrival baseline")
        time.sleep(0.8)
        mark = time.monotonic()
        stream(conn, patch(1, 2, edits=[edit(5, ", world!")]), client="fixture-2", owner="window-2")
        new_speed = wait_report(lambda r: r["tokens"] == 4 and r["averageTokensPerSecond"] is not None, mark)
        check(new_speed["streaming"], "text speed resumes after window replacement without socket reconnect")
        mark = time.monotonic()
        stream(conn, snapshot(0, "", "reloaded-window"), client="fixture-2", owner="window-2")
        stream(conn, patch(0, 1, edits=[edit(0, "Hello")]), client="fixture-2", owner="window-2")
        reloaded = wait_report(lambda r: r["model"] == "reloaded-window" and r.get("observedTokens") == 1, mark)
        check(reloaded["observedAverageTokensPerSecond"] is None and reloaded["usingSavedReading"],
              "same IPC client can restart its revision counter after renderer reload")
        time.sleep(0.8)
        mark = time.monotonic()
        stream(conn, patch(1, 2, edits=[edit(5, ", world!")]), client="fixture-2", owner="window-2")
        resumed = wait_report(lambda r: r["model"] == "reloaded-window" and r["tokens"] == 4 and
                              r["averageTokensPerSecond"] is not None, mark)
        check(resumed["streaming"], "lower baseline revision cannot freeze subsequent text updates")
        mark = time.monotonic()
        broadcast(conn, "ipc-connection-reset", {}, owner="window-2")
        wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        stream(conn, snapshot(0, "", "reset-window"), client="fixture-2", owner="window-2")
        reset = wait_report(lambda r: r["model"] == "reset-window", mark)
        check(reset["observedTokens"] == 0 and reset["observedHistorySamples"] == 0 and
              reset["historySamples"] == resumed["historySamples"],
              "IPC bridge reset establishes a fresh baseline without losing the saved graph")

        db.execute("INSERT INTO threads VALUES ('second', 'Second desktop', 0, 'user', 'appServer', 400, NULL)")
        db.commit()
        old = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        new = wait_message(conn, lambda m: m.get("method") == "thread-stream-following-changed")
        check(old["params"] == {"conversationId": "desktop", "hostId": "local", "following": False},
              "chat switch unsubscribes previous chat")
        check(new["params"] == {"conversationId": "second", "hostId": "local", "following": True},
              "chat switch subscribes the latest desktop chat")
        mark = time.monotonic()
        stream(conn, snapshot(0, "", "second-chat"), client="fixture-2", thread="second")
        stream(conn, patch(2, 3, edits=[edit(23, "old response")]), client="fixture-2")
        switched = wait_report(lambda r: r["model"] == "second-chat", mark)
        check(switched["tokens"] == 0 and switched["averageTokensPerSecond"] is None,
              "chat switch clears old speed and ignores previous chat events")
        check(switched["minimumTokensPerSecond"] is None and switched["maximumTokensPerSecond"] is None,
              "chat switch clears speed extrema")

        mark = time.monotonic()
        stream(conn, patch(0, 1, edits=[edit(0, "Hello")]), client="fixture-2", thread="second")
        wait_report(lambda r: r["observedTokens"] == 1, mark)
        time.sleep(0.8)
        mark = time.monotonic()
        stream(conn, patch(1, 2, edits=[edit(5, ", world!")]), client="fixture-2", thread="second")
        second_chat = wait_report(lambda r: r["tokens"] == 4 and r["averageTokensPerSecond"] is not None, mark)
        deadline = time.monotonic() + 8
        saved_record = None
        while time.monotonic() < deadline:
            if statistics_file.exists():
                saved_record = json.loads(statistics_file.read_text()).get("records", {}).get("second")
                if saved_record and saved_record["reading"]["tokens"] == 4:
                    break
            time.sleep(0.1)
        check(saved_record is not None and saved_record["reading"]["tokens"] == 4,
              "native monitor writes its last measured fragment to isolated local storage")
        check(saved_record["reading"]["minimum"] == second_chat["minimumTokensPerSecond"] and
              len(saved_record["reading"]["history"]) == second_chat["historySamples"],
              "saved native file preserves extrema and hover samples")
        check("Hello" not in statistics_file.read_text() and "world" not in statistics_file.read_text(),
              "persistent statistics never include streamed response text")

        # Relaunch the actual executable against the same numeric statistics.
        process.terminate()
        process.wait(timeout=5)
        collector.join(timeout=2)
        conn.close(); conn = None
        process = start_monitor()
        collector = threading.Thread(target=collect, daemon=True)
        collector.start()
        mark = time.monotonic()
        conn = handshake(server, "fixture-3", thread="second")
        resumed_after_restart = wait_report(lambda r: r["connected"] and r["tokens"] == 4 and
                                           r["usingSavedReading"], mark)
        check(resumed_after_restart["averageTokensPerSecond"] == second_chat["averageTokensPerSecond"] and
              resumed_after_restart["historySamples"] == second_chat["historySamples"] and
              not resumed_after_restart["streaming"],
              "executable restart restores frozen statistics and graph before new text arrives")
        mark = time.monotonic()
        stream(conn, snapshot(0, "", "second-chat"), client="fixture-3", thread="second")
        stream(conn, patch(0, 1, edits=[edit(0, "Hello")]), client="fixture-3", thread="second")
        resumed_first = wait_report(lambda r: r["observedTokens"] == 1, mark)
        check(resumed_first["usingSavedReading"] and resumed_first["tokens"] == 4 and
              resumed_first["averageTokensPerSecond"] == second_chat["averageTokensPerSecond"],
              "first batch after restart cannot erase the persisted result or invent new throughput")
        mark = time.monotonic()
        conn.sendall(struct.pack("<I", 0xFFFFFFFF))
        invalid = wait_report(lambda r: not r["connected"], mark)
        check(invalid["tokens"] == 4 and invalid["usingSavedReading"] and not invalid["streaming"],
              "oversized IPC frame disconnects cleanly while retaining saved statistics")
        check(process.poll() is None, "native monitor survives all recovery cases")
    finally:
        if conn is not None:
            conn.close()
        server.close()
        db.close()
        process.terminate()
        process.wait(timeout=5)
        collector.join(timeout=2)
        errors = process.stderr.read()
        if errors:
            print(errors)

result = {"passed": len(checks), "checks": checks, "numericSamples": len(reports),
          "scope": "Isolated native IPC integration; synthetic text; no real Codex state modified"}
(ROOT / "artifacts").mkdir(exist_ok=True)
(ROOT / "artifacts/integration-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(f"PASS: {len(checks)} native IPC checks; {len(reports)} numeric samples")
