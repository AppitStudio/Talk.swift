/// Process-wide budget survives individual server/grant destruction. A cancelled
/// noncooperative handler holds its slot until it actually returns.
actor HandlerCapacity {
    static let shared = HandlerCapacity()
    private(set) var retained = 0
    func acquire() -> Bool {
        guard retained < 128 else { return false }
        retained += 1
        return true
    }
    func release() { retained -= 1 }
}
