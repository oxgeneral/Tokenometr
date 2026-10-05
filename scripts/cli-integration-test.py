#!/usr/bin/env python3
"""Native CLI observer fixture: standard library only, no real Codex mutations."""
import base64
import hashlib
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
ARTIFACTS = ROOT / "artifacts"
ARTIFACTS.mkdir(exist_ok=True)
EXECUTABLE = ROOT / "dist/Tokenometr.app/Contents/MacOS/Tokenometr"
checks = []
reports = []


def check(condition, label):
    if not condition:
        raise AssertionError(label)
    checks.append(label)


def frame(value, opcode=1):
    body = json.dumps(value, ensure_ascii=False).encode() if isinstance(value, dict) else value
    n = len(body)
    header = bytes([0x80 | opcode, n]) if n < 126 else bytes([0x80 | opcode, 126]) + struct.pack(">H", n)
    return header + body


def exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def read_frame(conn):
    a, b = exact(conn, 2)
    n = b & 127
    if n == 126:
        n = struct.unpack(">H", exact(conn, 2))[0]
    if n == 127:
        n = struct.unpack(">Q", exact(conn, 8))[0]
    check(b & 128, "native WebSocket writes use client masking")
    mask, body = exact(conn, 4), exact(conn, n)
    return a & 15, bytes(v ^ mask[i % 4] for i, v in enumerate(body))


with tempfile.TemporaryDirectory(prefix="tm-cli-", dir="/tmp") as directory:
    # Longer than Darwin sun_path: account managers commonly use long homes.
    home = Path(directory) / ("account-" + "x" * 110)
    control = home / "app-server-control"
    control.mkdir(parents=True)
    (home / "ipc").mkdir()
    db = sqlite3.connect(home / "state_5.sqlite")
    db.execute("CREATE TABLE threads (id TEXT,title TEXT,archived INT,thread_source TEXT,source TEXT,updated_at INT,reasoning_effort TEXT)")
    db.execute("INSERT INTO threads VALUES ('desktop','Desktop fixture',0,'user','vscode',100,'xhigh')")
    db.commit()
    server = socket.socket(socket.AF_UNIX)
    previous_directory = os.getcwd()
    os.chdir(control)
    server.bind("real.sock")
    os.chdir(previous_directory)
    (control / "app-server-control.sock").symlink_to("real.sock")
    server.listen(4)
    server.settimeout(12)
    desktop_server = socket.socket(socket.AF_UNIX)
    os.chdir(home / "ipc")
    desktop_server.bind("ipc.sock")
    os.chdir(previous_directory)
    desktop_server.listen(4); desktop_server.settimeout(12)
    output = queue.Queue()
    errors = queue.Queue()
    statistics = home / "statistics.json"
    active = [None]
    desktop_active = [None]
    desktop_ready = threading.Event()
    desktop_revision = [0]
    transport_lock = threading.Lock()
    stop = threading.Event()
    subscribed = threading.Event()
    pongs = threading.Event()
    methods = []
    session_ids = ["cli", "desktop", "helper"]

    def desktop_send(change):
        body = json.dumps({"type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "desktop-window", "version": 11,
                           "params": {"hostId": "local", "conversationId": "desktop", "change": change}}).encode()
        desktop_active[0].sendall(struct.pack("<I", len(body)) + body)

    def desktop_worker():
        try:
            while not stop.is_set():
                conn, _ = desktop_server.accept(); desktop_active[0] = conn; conn.settimeout(12)
                try:
                    while not stop.is_set():
                        message = json.loads(exact(conn, struct.unpack("<I", exact(conn, 4))[0]))
                        if message.get("method") == "initialize":
                            body = json.dumps({"type": "response", "method": "initialize", "result": {"clientId": "desktop-observer"}}).encode()
                            conn.sendall(struct.pack("<I", len(body)) + body)
                        elif message.get("method") == "thread-stream-following-changed" and message["params"]["following"]:
                            desktop_send({"type": "snapshot", "revision": desktop_revision[0], "conversationState": {
                                "latestModel": "desktop-fixture", "latestReasoningEffort": "xhigh", "turns": [{"status": "inProgress", "items": [{"type": "agentMessage", "id": "desktop-answer", "text": ""}]}]}})
                            desktop_ready.set()
                except (EOFError, OSError):
                    pass
        except Exception as error:
            if not stop.is_set():
                errors.put(error)

    def desktop_delta(offset, text):
        base = desktop_revision[0]; desktop_revision[0] += 1
        desktop_send({"type": "patches", "baseRevision": base, "revision": desktop_revision[0], "patches": [],
                      "acceptedTextChanges": [{"key": {"itemId": "desktop-answer"}, "target": {"field": "text"}, "edits": [{"at": offset, "deleteCount": 0, "insert": text}]}]})

    def send(message):
        with transport_lock:
            active[0].sendall(frame(message))

    def notification(method, params):
        send({"method": method, "params": params})

    def cli_server():
        try:
            while not stop.is_set():
                conn, _ = server.accept()
                conn.settimeout(12)
                header = b""
                while b"\r\n\r\n" not in header:
                    header += conn.recv(1024)
                fields = dict(line.split(": ", 1) for line in header.decode().split("\r\n")[1:] if ": " in line)
                key = fields["Sec-WebSocket-Key"]
                accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                response = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode()
                conn.sendall(response[:10]); conn.sendall(response[10:])
                active[0] = conn
                try:
                    while not stop.is_set():
                        opcode, body = read_frame(conn)
                        if opcode == 10:
                            check(body == b"heartbeat", "native observer answers ping without counting it")
                            pongs.set()
                            continue
                        message = json.loads(body)
                        method = message.get("method")
                        methods.append(method)
                        check(method in {"initialize", "initialized", "thread/loaded/list", "thread/read", "thread/resume", "thread/unsubscribe"}, "CLI observer sends only discovery and subscription calls")
                        if method == "initialized":
                            continue
                        params = message["params"]
                        if method == "initialize":
                            result = {"userAgent": "fixture"}
                        elif method == "thread/loaded/list":
                            result = {"data": session_ids[:], "nextCursor": None}
                        elif method == "thread/read":
                            id = params["threadId"]
                            result = {"thread": {"id": id, "source": "vscode" if id == "cli" else "cli", "threadSource": "agent" if id in {"desktop", "helper"} else "user", "name": "CLI fixture", "model": "cli-fixture", "reasoningEffort": "high", "status": {"type": "idle"}}}
                        elif method == "thread/resume":
                            check(params == {"threadId": "cli", "excludeTurns": True}, "only loaded user CLI is subscribed without configuration overrides")
                            result = {"thread": {"id": "cli", "source": "vscode", "turns": [{"items": [{"type": "agentMessage", "text": "old history"}]}]}, "model": "cli-fixture", "reasoningEffort": "xhigh"}
                        else:
                            result = {}
                        with transport_lock:
                            conn.sendall(frame({"id": message["id"], "result": result}))
                        if method == "thread/resume":
                            subscribed.set()
                except (EOFError, ConnectionResetError, OSError):
                    pass
        except Exception as error:
            if not stop.is_set():
                errors.put(error)

    worker = threading.Thread(target=cli_server, daemon=True)
    worker.start()
    threading.Thread(target=desktop_worker, daemon=True).start()

    def start_monitor():
        process = subprocess.Popen([str(EXECUTABLE), "--diagnose", "--duration", "90", "--statistics-file", str(statistics)],
                                   env={**os.environ, "CODEX_HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def collect():
            for line in process.stdout:
                r = json.loads(line); reports.append(r); output.put((time.monotonic(), r))
        threading.Thread(target=collect, daemon=True).start()
        return process

    def wait_report(predicate, since=None):
        deadline = time.monotonic() + 12
        since = since or 0
        while time.monotonic() < deadline:
            if not errors.empty():
                raise errors.get()
            try:
                arrived, r = output.get(timeout=0.2)
            except queue.Empty:
                continue
            if arrived >= since and predicate(r):
                return r
        raise AssertionError(f"missing native CLI state; last: {reports[-1:]}")

    def delta(text, item="answer", turn="turn", thread="cli"):
        notification("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": item, "delta": text})

    process = start_monitor()
    try:
        check(subscribed.wait(12), "owned socket symlink and long account path connect without changing process directory")
        check(desktop_ready.wait(12), "desktop and CLI connections coexist")
        mark = time.monotonic()
        with transport_lock:
            active[0].sendall(frame(b"heartbeat", opcode=9))
        check(pongs.wait(5), "live native WebSocket ping/pong")
        delta("foreign text", thread="desktop")
        notification("item/reasoning/textDelta", {"threadId": "cli", "turnId": "turn", "itemId": "r", "delta": "hidden"})
        notification("thread/tokenUsage/updated", {"threadId": "cli", "outputTokens": 999999})
        send({"id": "approval-from-owner", "method": "item/commandExecution/requestApproval", "params": {"threadId": "cli"}})
        baseline = wait_report(lambda r: r["source"] == "Codex" and r["tokens"] == 0, mark)
        check(baseline["historySamples"] == 0, "stored history, reasoning, usage and foreign events produce no measurement")
        mark = time.monotonic()
        for text in ["Hello", ", world!", " Привет", " 🙂", " ещё текст", " конец"]:
            delta(text); time.sleep(0.35)
        first = wait_report(lambda r: r["source"] == "Codex CLI" and r["historySamples"] >= 4 and r["averageTokensPerSecond"] is not None, mark)
        check(first["minimumTokensPerSecond"] is not None and first["maximumTokensPerSecond"] >= first["minimumTokensPerSecond"], "native CLI own timings expose min average max and graph")
        notification("item/completed", {"threadId": "cli", "turnId": "turn", "item": {"id": "answer", "type": "agentMessage", "text": "full completed payload is not a delta"}})
        mark = time.monotonic()
        finished = wait_report(lambda r: r["source"] == "Codex CLI" and not r["streaming"] and r["historySamples"] == 6, mark)
        check(finished["tokens"] >= first["tokens"] and finished["durationSeconds"] < 3, "CLI completion retains the whole observed fragment without tool waiting or duplicate text")
        mark = time.monotonic()
        desktop_delta(0, "Hello"); time.sleep(0.4); desktop_delta(5, ", world!")
        desktop_reading = wait_report(lambda r: r["source"] == "Codex" and r["model"] == "desktop-fixture" and r["observedHistorySamples"] == 2, mark)
        check(desktop_reading["tokens"] == 4 and desktop_reading["textChanges"] == 2, "new desktop text takes over without mixing CLI samples")
        notification("thread/tokenUsage/updated", {"threadId": "cli", "outputTokens": 999999})
        mark = time.monotonic()
        still_desktop = wait_report(lambda r: r["source"] == "Codex" and r["model"] == "desktop-fixture", mark)
        check(still_desktop["tokens"] == 4, "CLI service events cannot divert the selected desktop source")
        mark = time.monotonic()
        delta("single batch", item="next", turn="next-turn")
        saved = wait_report(lambda r: r["usingSavedReading"] and r["observedTokens"] > 0, mark)
        check(saved["source"] == "Codex CLI" and saved["tokens"] == finished["tokens"] and saved["historySamples"] == finished["historySamples"], "new CLI text takes over while an untimed message preserves that session's previous statistics")
        mark = time.monotonic()
        delta(" with a timed continuation", item="next", turn="next-turn")
        replacement = wait_report(lambda r: not r["usingSavedReading"] and r["observedHistorySamples"] == 2, mark)
        check(replacement["durationSeconds"] > 0, "a measurable next CLI fragment replaces the saved reading")
        notification("turn/completed", {"threadId": "cli", "turn": {"id": "next-turn", "status": "completed"}})
        mark = time.monotonic()
        stopped = wait_report(lambda r: not r["streaming"] and r["historySamples"] == 2, mark)
        time.sleep(2.2)
        check(statistics.exists(), "CLI numeric statistics persist to disk")
        contents = statistics.read_text()
        check("Hello" not in contents and "single batch" not in contents, "CLI conversation text is never stored")
        subscribed.clear()
        with transport_lock:
            active[0].shutdown(socket.SHUT_RDWR); active[0].close()
        check(subscribed.wait(12), "CLI observer reconnects and resubscribes")
        mark = time.monotonic()
        restored = wait_report(lambda r: r["source"] == "Codex CLI" and r["connected"] and r["usingSavedReading"], mark)
        check(restored["tokens"] == stopped["tokens"] and restored["minimumTokensPerSecond"] == stopped["minimumTokensPerSecond"], "CLI reconnection restores statistics without replaying history")
        process.terminate(); process.wait(5)
        subscribed.clear()
        process = start_monitor()
        check(subscribed.wait(12), "native restart reconnects to existing CLI")
        restarted = wait_report(lambda r: r["source"] == "Codex CLI" and r["usingSavedReading"] and r["connected"])
        check(restarted["tokens"] == stopped["tokens"] and restarted["historySamples"] == stopped["historySamples"], "native restart retains CLI tokens and hover history")
        result = {"checks": len(checks), "passed": True, "subscriptionMethods": sorted(set(methods)), "finished": finished, "restored": restarted}
        (ROOT / "artifacts/cli-integration-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(f"PASS: {len(checks)} native CLI checks")
    finally:
        stop.set()
        if process.poll() is None:
            process.terminate(); process.wait(5)
        if active[0]:
            active[0].close()
        if desktop_active[0]:
            desktop_active[0].close()
        server.close(); desktop_server.close(); db.close()
