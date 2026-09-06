import Foundation

public enum PairingClient {
    public static func pair(using invitation: PairingInvitation) async throws -> PairingRecord {
        guard invitation.expiresAt > Date() else { throw TalkError.invitationExpired }
        let client = try TalkClient(port: invitation.port, credential: invitation.credential)
        do {
            try await client.connect()
            let payload = try await client.request(action: "talk.pair", timeout: 120)
            let record = try payload.decode(PairingRecord.self)
            try record.validate()
            guard record.providerBundleID == invitation.providerBundleID,
                  record.credential.id != invitation.credential.id else { throw TalkError.invalidMessage }
            await client.close()
            return record
        } catch {
            await client.close()
            throw error
        }
    }
}
