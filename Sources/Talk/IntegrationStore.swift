import Foundation

public protocol IntegrationPersistence: Sendable {
    func loadRecords() async throws -> [PairingRecord]
    func saveRecords(_ records: [PairingRecord]) async throws
}

/// One atomic protected archive, with independent credentials and grants. The
/// owner must share one store instance for a service, never race whole archives.
public actor IntegrationStore {
    private let persistence: any IntegrationPersistence
    private var records: [PairingRecord] = []
    private var loaded = false
    private var busy = false
    private var unresolved = false

    public init(persistence: any IntegrationPersistence) { self.persistence = persistence }

    public func reload() async throws -> [PairingRecord] {
        guard !busy else { throw TalkError.busy }
        busy = true
        defer { busy = false }
        let result = try await persistence.loadRecords()
        try IntegrationArchive.validate(result)
        records = result
        loaded = true
        unresolved = false
        return result
    }

    public func all() throws -> [PairingRecord] {
        guard loaded, !unresolved else { throw TalkError.credentialOperationPending }
        return records
    }

    /// Call only after explicit provider consent (or receipt of its paired grant).
    /// Permission replacement rotates keys and never edits a live grant in place.
    public func insert(_ record: PairingRecord) async throws {
        var next = try all()
        guard !next.contains(where: { $0.credential.id == record.credential.id }) else { throw TalkError.busy }
        if let old = record.replacesID, let previous = next.first(where: { $0.credential.id == old }) {
            guard previous.providerBundleID == record.providerBundleID else { throw TalkError.permissionDenied }
            next.removeAll { $0.credential.id == old }
        }
        next.append(record)
        try await commit(next)
    }

    public func remove(_ id: UUID) async throws {
        try await commit(all().filter { $0.credential.id != id })
    }

    private func commit(_ next: [PairingRecord]) async throws {
        guard !busy else { throw TalkError.busy }
        try IntegrationArchive.validate(next)
        busy = true
        defer { busy = false }
        do { try await persistence.saveRecords(next); records = next }
        catch {
            // Freeze writes until explicit reload. Even a failed save can have
            // reached Security; don't overwrite its later result with stale data.
            unresolved = true
            throw error
        }
    }
}

/// A single bounded archive format. Invalid or obsolete storage fails closed.
enum IntegrationArchive {
    private struct Archive: Codable { let version: Int; let records: [PairingRecord] }
    static func validate(_ records: [PairingRecord]) throws {
        guard records.count <= 16, Set(records.map { $0.credential.id }).count == records.count else { throw TalkError.credentialStorage }
        for record in records { try record.validate() }
    }
    static func decode(_ data: Data) throws -> [PairingRecord] {
        guard data.count <= 131_072 else { throw TalkError.credentialStorage }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 2 else {
            throw TalkError.credentialStorage
        }
        let result = archive.records
        try validate(result)
        return result
    }
    static func encode(_ records: [PairingRecord]) throws -> Data {
        try validate(records)
        let data = try JSONEncoder().encode(Archive(version: 2, records: records))
        guard data.count <= 131_072 else { throw TalkError.credentialStorage }
        return data
    }
}
