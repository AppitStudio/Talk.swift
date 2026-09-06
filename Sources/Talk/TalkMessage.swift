import Foundation

public struct TalkMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, response, event }
    public let protocolVersion: Int
    public let kind: Kind
    public let id: UUID
    public let action: String
    public let payload: JSONValue
    public let error: TalkError?

    public init(kind: Kind, id: UUID = UUID(), action: String, payload: JSONValue = .null, error: TalkError? = nil) {
        self.protocolVersion = 1
        self.kind = kind
        self.id = id
        self.action = action
        self.payload = payload
        self.error = error
    }

    public func validate() throws {
        guard protocolVersion == 1 else { throw TalkError.unsupportedVersion }
        guard action.isEmpty == false, action.utf8.count <= 128,
              kind == .response || error == nil else { throw TalkError.invalidMessage }
    }
}
