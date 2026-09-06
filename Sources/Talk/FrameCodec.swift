import Foundation

public enum FrameCodec {
    // Small control messages only. Bulk data is deliberately unsupported.
    public static let maximumPayloadBytes = 65_536

    public static func encode(_ message: TalkMessage) throws -> Data {
        try message.validate()
        let body = try JSONEncoder().encode(message)
        guard body.count <= maximumPayloadBytes else { throw TalkError.invalidFrame }
        let count = UInt32(body.count)
        var result = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(body)
        return result
    }

    public static func payloadLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw TalkError.invalidFrame }
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximumPayloadBytes else { throw TalkError.invalidFrame }
        return Int(count)
    }

    // Check depth before recursive Codable allocation. String braces and escaped
    // quotes are ignored; the JSON decoder still validates the actual grammar.
    private static func checkNesting(_ bytes: Data) throws {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 91 || byte == 123 {
                depth += 1
                guard depth <= 32 else { throw TalkError.invalidMessage }
            } else if byte == 93 || byte == 125 { depth -= 1 }
        }
    }

    public static func decode(_ payload: Data) throws -> TalkMessage {
        guard payload.isEmpty == false, payload.count <= maximumPayloadBytes else { throw TalkError.invalidFrame }
        try checkNesting(payload)
        do {
            let message = try JSONDecoder().decode(TalkMessage.self, from: payload)
            try message.validate()
            return message
        } catch let error as TalkError { throw error }
        catch { throw TalkError.invalidMessage }
    }
}
