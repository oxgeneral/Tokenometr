import Foundation
import CryptoKit

struct WebSocketPacket {
    let opcode: UInt8
    let data: Data
}

/// RFC 6455 framing for the CLI's existing Unix control socket.
struct WebSocketFramer {
    private var buffer = Data()
    private var fragmented: Data?
    private let limit = 8 * 1024 * 1024

    mutating func receive(_ data: Data) throws -> [WebSocketPacket] {
        buffer.append(data)
        var packets: [WebSocketPacket] = []
        while buffer.count >= 2 {
            let bytes = Array(buffer.prefix(10))
            let final = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0f
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 == 0 else { throw FramingError.oversized }
            var size = Int(bytes[1] & 0x7f), header = 2
            if size == 126 {
                guard bytes.count >= 4 else { break }
                size = Int(bytes[2]) * 256 + Int(bytes[3]); header = 4
            } else if size == 127 {
                guard bytes.count >= 10 else { break }
                let value = bytes[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard value <= limit else { throw FramingError.oversized }
                size = Int(value); header = 10
            }
            guard size <= limit else { throw FramingError.oversized }
            guard buffer.count >= header + size else { break }
            let start = buffer.startIndex
            let body = buffer.subdata(in: (start + header)..<(start + header + size))
            buffer.removeFirst(header + size)
            if opcode >= 8 {
                guard final, size <= 125, [8, 9, 10].contains(opcode) else { throw FramingError.oversized }
                packets.append(WebSocketPacket(opcode: opcode, data: body))
            } else if opcode == 1 {
                guard fragmented == nil else { throw FramingError.oversized }
                if final { packets.append(WebSocketPacket(opcode: 1, data: body)) }
                else { fragmented = body }
            } else if opcode == 0, fragmented != nil {
                guard fragmented!.count + size <= limit else { throw FramingError.oversized }
                fragmented!.append(body)
                if final { packets.append(WebSocketPacket(opcode: 1, data: fragmented!)); fragmented = nil }
            } else { throw FramingError.oversized }
        }
        guard buffer.count <= limit + 10 else { throw FramingError.oversized }
        return packets
    }

    static func encode(_ data: Data, opcode: UInt8 = 1) -> Data {
        let count = data.count
        var result = Data([0x80 | opcode])
        if count < 126 { result.append(0x80 | UInt8(count)) }
        else if count <= 65535 {
            result.append(0xfe); result.append(UInt8(count >> 8)); result.append(UInt8(count & 255))
        } else {
            result.append(0xff)
            var length = UInt64(count).bigEndian
            result.append(withUnsafeBytes(of: &length) { Data($0) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        result.append(contentsOf: mask)
        result.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }

    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
}
