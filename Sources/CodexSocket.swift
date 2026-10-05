import Foundation
import Darwin

// macOS offers a thread-local directory for Unix sockets whose absolute paths
// exceed sun_path. Restore it immediately; the process directory never changes.
@_silgen_name("pthread_fchdir_np") private func threadDirectory(_ fd: Int32) -> Int32

enum FramingError: Error { case oversized }

struct IPCFramer {
    private var buffer = Data()
    private let limit = 64 * 1024 * 1024

    mutating func receive(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard size > 0 && size <= limit else { throw FramingError.oversized }
            guard buffer.count >= size + 4 else { break }
            let start = buffer.startIndex
            let body = buffer.subdata(in: (start + 4)..<(start + size + 4))
            buffer.removeFirst(size + 4)
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            messages.append(message)
        }
        return messages
    }

    static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(body.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(body)
        return data
    }
}

/// A passive client of the desktop app's existing local IPC router.
/// It never starts an app-server and never sends thread or turn mutations.
final class CodexSocket {
    enum Wire { case desktop, websocket }
    let queue: DispatchQueue
    let path: String
    var onMessage: (([String: Any]) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var framer = IPCFramer()
    private var pendingWrite = Data()
    private var writer: DispatchSourceWrite?
    private let wire: Wire
    private var websocket = WebSocketFramer()
    private var upgrade = Data()
    private var upgraded = false
    private var upgradeKey = ""
    private var openedAt = 0.0

    init(path: String, queue: DispatchQueue, wire: Wire = .desktop) {
        self.path = path; self.queue = queue; self.wire = wire
    }

    func connectIfNeeded() {
        guard fd < 0 else {
            if wire == .websocket, !upgraded, monotonicTime() - openedAt > 5 { disconnect() }
            return
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid() else { return }
        let socketPath = (metadata.st_mode & S_IFMT) == S_IFLNK
            ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        guard lstat(socketPath, &metadata) == 0, metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFSOCK else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        var bytes = Array(socketPath.utf8) + [0]
        var directory: Int32 = -1
        if bytes.count > MemoryLayout.size(ofValue: address.sun_path) {
            let url = URL(fileURLWithPath: socketPath)
            directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
            guard directory >= 0, threadDirectory(directory) == 0 else {
                if directory >= 0 { close(directory) }; close(descriptor); return
            }
            bytes = Array(url.lastPathComponent.utf8) + [0]
        }
        defer { if directory >= 0 { _ = threadDirectory(-1); close(directory) } }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(descriptor); return }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        fd = descriptor
        framer = IPCFramer(); websocket = WebSocketFramer(); upgrade = Data(); upgraded = false
        openedAt = monotonicTime()
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler { close(descriptor) }
        source = reader
        reader.resume()
        if wire == .desktop { onConnection?(true) }
        else {
            upgradeKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            pendingWrite.append(Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(upgradeKey)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8))
            flush()
        }
    }

    func send(_ message: [String: Any]) {
        guard fd >= 0 else { return }
        let bytes: Data
        if wire == .desktop {
            guard let encoded = try? IPCFramer.encode(message) else { return }; bytes = encoded
        } else {
            guard upgraded, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            bytes = WebSocketFramer.encode(body)
        }
        pendingWrite.append(bytes)
        flush()
    }

    private func flush() {
        while !pendingWrite.isEmpty && fd >= 0 {
            let written = pendingWrite.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 { pendingWrite.removeFirst(written); continue }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    let output = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    output.setEventHandler { [weak self] in self?.flush() }
                    writer = output; output.resume()
                }
                return
            }
            disconnect(); return
        }
        writer?.cancel(); writer = nil
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while fd >= 0 {
            let size = Darwin.read(fd, &chunk, chunk.count)
            if size == 0 { disconnect(); return }
            if size < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                disconnect(); return
            }
            do {
                var data = Data(chunk.prefix(size))
                if wire == .desktop {
                    for message in try framer.receive(data) { onMessage?(message) }
                } else {
                    if !upgraded {
                        upgrade.append(data)
                        guard let end = upgrade.range(of: Data("\r\n\r\n".utf8)) else {
                            if upgrade.count > 8192 { disconnect(); return }; continue
                        }
                        guard end.upperBound <= 8192,
                              let header = String(data: upgrade[..<end.lowerBound], encoding: .utf8) else { disconnect(); return }
                        let lines = header.components(separatedBy: "\r\n")
                        var fields: [String: String] = [:]
                        for line in lines.dropFirst() {
                            if let colon = line.firstIndex(of: ":") {
                                fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            }
                        }
                        guard lines.first?.split(separator: " ").dropFirst().first == "101",
                              fields["sec-websocket-accept"] == WebSocketFramer.accept(for: upgradeKey),
                              fields["upgrade"]?.lowercased() == "websocket",
                              fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true
                        else { disconnect(); return }
                        data = Data(upgrade[end.upperBound...]); upgrade = Data(); upgraded = true
                        onConnection?(true)
                    }
                    for packet in try websocket.receive(data) {
                        if packet.opcode == 8 { disconnect(); return }
                        if packet.opcode == 9 { pendingWrite.append(WebSocketFramer.encode(packet.data, opcode: 10)); flush() }
                        if packet.opcode == 1, let message = try JSONSerialization.jsonObject(with: packet.data) as? [String: Any] {
                            onMessage?(message)
                        }
                    }
                }
            } catch { disconnect(); return }
        }
    }

    func disconnect() {
        guard fd >= 0 else { return }
        fd = -1
        writer?.cancel(); writer = nil
        source?.cancel(); source = nil
        pendingWrite = Data(); framer = IPCFramer(); websocket = WebSocketFramer(); upgraded = false; upgrade = Data()
        onConnection?(false)
    }
}
