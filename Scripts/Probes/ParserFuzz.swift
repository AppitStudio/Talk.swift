// Deterministic mutation runner under AddressSanitizer. The installed Apple
// Swift compiler does not support libFuzzer on arm64. No coverage-guided claim.
import Darwin
import Foundation
import CryptoKit

private func exercise(_ bytes: Data) -> (Int, Int, Int) {
    _ = try? FrameCodec.payloadLength(bytes.prefix(4))
    var accepted = 0, schemas = 0, invitations = 0
    if let decoded = try? FrameCodec.decode(bytes), let encoded = try? FrameCodec.encode(decoded) {
        accepted = 1
        guard let again = try? FrameCodec.decode(encoded.dropFirst(4)),
              again.id == decoded.id, again.action == decoded.action,
              again.payload == decoded.payload, again.kind == decoded.kind,
              again.error == decoded.error else { fatalError("synthetic frame round-trip invariant") }
    }
    if bytes.count <= 4096, let text = String(data: bytes, encoding: .utf8) {
        if (try? PairingInvitation.parse(text, now: Date(timeIntervalSince1970: 1))) != nil { invitations = 1 }
    }
    if let schema = try? ContractSchema.load(bytes) {
        schemas = 1
        if let exported = try? schema.exported() {
            guard let again = try? ContractSchema.load(exported), again == schema else {
                fatalError("synthetic schema round-trip invariant")
            }
        }
    }
    return (accepted, schemas, invitations)
}

@main
private enum ParserMutations {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let seconds = Int(CommandLine.arguments[1]),
              (5...1800).contains(seconds) else { exit(2) }
        let replay = ProcessInfo.processInfo.environment["TALK_FUZZ_REPLAY_CASE"].flatMap(Int.init)
        let seed: UInt64 = 20_260_906
        var random = Generator(state: seed)
        let frame = TalkMessage(kind: .request, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                action: "synthetic.read", payload: .object(["key": .string("value\\\"\n")]))
        let encoder = JSONEncoder()
        // Seed bytes must not depend on process-randomized dictionary ordering.
        encoder.outputFormatting = [.sortedKeys]
        let valid = try encoder.encode(frame)
        let large = try encoder.encode(TalkMessage(kind: .request, id: frame.id, action: "synthetic.read",
                                                        payload: .string(String(repeating: "x", count: 65_300))))
        let syntheticInvitation: [String: Any] = ["version": 1, "port": 1, "providerBundleID": "dev.talk.synthetic.fuzz",
            "expiresAt": 1_000_000_000, "credential": ["id": frame.id.uuidString, "secret": Data(repeating: 0, count: 32).base64EncodedString()]]
        let invitation = Data(("talk-pair-v1:" + (try JSONSerialization.data(withJSONObject: syntheticInvitation, options: [.sortedKeys])).base64EncodedString()).utf8)
        let schema = Data(#"{"schemaVersion":1,"contractID":"dev.talk.synthetic.fuzz","contractVersion":"1.0.0","name":"Synthetic","types":[],"events":[],"actions":[{"id":"synthetic.read","symbol":"read","method":"read","scope":"synthetic.read","input":"Void","output":"String","mutation":false}]}"#.utf8)
        let seeds: [Data] = [Data(), Data("{}".utf8), Data("GET / HTTP/1.1".utf8), valid, large,
                            Data(repeating: 255, count: 4), Data([0, 1, 0, 0]),
                            Data("talk-pair-v1:invalid".utf8), Data("{\"payload\":\"\\\\\\\"[{}]\"}".utf8), invitation, schema]
        emit("mutation begin seed=\(seed) seconds=\(seconds) maxBytes=65540 sanitizer=address coverageGuided=false")
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var cases = 0, accepted = 0, acceptedSchemas = 0, acceptedInvitations = 0
        repeat {
            cases += 1
            autoreleasepool {
                var bytes = seeds[random.next(seeds.count)]
                let operation = random.next(8)
                switch operation {
                case 0: // Unchanged positive and negative controls recur.
                    break
                case 1:
                    if !bytes.isEmpty { bytes[random.next(bytes.count)] ^= UInt8(1 << random.next(8)) }
                case 2:
                    if !bytes.isEmpty { bytes.remove(at: random.next(bytes.count)) }
                case 3:
                    bytes.insert(UInt8(random.next(256)), at: random.next(bytes.count + 1))
                case 4:
                    bytes = Data(bytes.prefix(random.next(bytes.count + 1)))
                case 5:
                    bytes.append(contentsOf: (0..<random.next(512)).map { _ in UInt8(random.next(256)) })
                case 6:
                    let depth = random.next(2000)
                    bytes = Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
                default:
                    if !bytes.isEmpty {
                        let location = random.next(bytes.count)
                        let count = min(random.next(256), bytes.count - location)
                        let byte = UInt8(random.next(256))
                        bytes.replaceSubrange(location..<(location + count), with: repeatElement(byte, count: count))
                    }
                }
                bytes = Data(bytes.prefix(65_540))
                if replay == nil || replay == cases {
                    if replay != nil {
                        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        emit("mutation replay case=\(cases) syntheticInputSHA256=\(digest)")
                    }
                    let result = exercise(bytes)
                    accepted += result.0; acceptedSchemas += result.1; acceptedInvitations += result.2
                }
            }
            if cases.isMultiple(of: 25_000) { emit("mutation progress cases=\(cases) acceptedFrames=\(accepted)") }
            if replay == cases { break }
        } while replay.map({ cases < $0 }) ?? ((clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) < UInt64(seconds) * 1_000_000_000)
        emit("mutation complete cases=\(cases) acceptedFrames=\(accepted) acceptedSchemas=\(acceptedSchemas) acceptedInvitations=\(acceptedInvitations) result=PASS")
    }

    static func emit(_ text: String) { try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8)) }
    struct Generator {
        var state: UInt64
        mutating func next(_ limit: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(limit))
        }
    }
}
