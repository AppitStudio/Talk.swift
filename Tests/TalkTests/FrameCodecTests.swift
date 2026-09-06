import Foundation
import Testing
@testable import Talk

struct FrameCodecTests {
    @Test func roundTrip() throws {
        let message = TalkMessage(kind: .request, action: "scene.select", payload: .object(["id": .string("focus")]))
        let bytes = try FrameCodec.encode(message)
        #expect(try FrameCodec.payloadLength(bytes.prefix(4)) == bytes.count - 4)
        let decoded = try FrameCodec.decode(bytes.dropFirst(4))
        #expect(decoded.id == message.id)
        #expect(decoded.payload == message.payload)
    }

    @Test(arguments: [Data(), Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 1, 0, 1]), Data([1, 2, 3])])
    func rejectsInvalidLength(header: Data) {
        #expect(throws: TalkError.invalidFrame) { try FrameCodec.payloadLength(header) }
    }

    @Test func rejectsHTTPAndMalformedJSON() {
        #expect(throws: TalkError.invalidMessage) { try FrameCodec.decode(Data("GET / HTTP/1.1".utf8)) }
        #expect(throws: TalkError.invalidMessage) { try FrameCodec.decode(Data("{}".utf8)) }
    }

    @Test func rejectsOversizedOutput() {
        let message = TalkMessage(kind: .request, action: "large", payload: .string(String(repeating: "x", count: 65_536)))
        #expect(throws: TalkError.invalidFrame) { try FrameCodec.encode(message) }
    }

    @Test func rejectsFutureProtocol() throws {
        let message = TalkMessage(kind: .request, action: "scene.read")
        let bytes = try JSONEncoder().encode(message)
        let string = try #require(String(data: bytes, encoding: .utf8))
        let future = string.replacingOccurrences(of: "\"protocolVersion\":1", with: "\"protocolVersion\":2")
        #expect(throws: TalkError.unsupportedVersion) { try FrameCodec.decode(Data(future.utf8)) }
    }
}
