import Testing
@testable import Talk

struct TransportDiagnosticBufferTests {
    @Test
    func retainsLatestEventsAndIndependentSnapshots() {
        let buffer = TransportDiagnosticBuffer()
        for index in 0..<256 { buffer.record(String(index)) }
        let snapshot = buffer.snapshot()
        for index in 256..<300 { buffer.record(String(index)) }
        #expect(snapshot == (0..<256).map(String.init))
        #expect(buffer.snapshot() == (44..<300).map(String.init))
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentWritersAndReadersKeepUniqueIDsAndBoundedEvents() async {
        let buffer = TransportDiagnosticBuffer()
        let identifiers = await withTaskGroup(of: [UInt64].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var identifiers: [UInt64] = []
                    for _ in 0..<128 {
                        let id = buffer.identifier()
                        identifiers.append(id)
                        buffer.record(String(id))
                        #expect(buffer.snapshot().count <= 256)
                    }
                    return identifiers
                }
            }
            var identifiers: [UInt64] = []
            for await batch in group { identifiers.append(contentsOf: batch) }
            return identifiers
        }
        #expect(identifiers.count == 2048)
        #expect(Set(identifiers) == Set(UInt64(1)...UInt64(2048)))
        #expect(buffer.snapshot().count == 256)
    }
}
