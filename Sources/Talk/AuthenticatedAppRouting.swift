import AppKit
import Carbon
import Security

/// An expected signing identity supplied by the integration's developer.
/// Bundle identifiers or discovery metadata alone never establish this identity.
public struct AppIdentity: Codable, Sendable, Hashable {
    public let bundleID: String
    public let teamID: String

    public init(bundleID: String, teamID: String) {
        self.bundleID = bundleID
        self.teamID = teamID
    }
}

/// A running application whose Apple-issued signature has been checked.
public struct VerifiedApplication: Sendable {
    public let identity: AppIdentity
    public let applicationURL: URL
    public let processIdentifier: Int32
    // Keep the kernel process generation for authenticated incoming messages.
    // A PID by itself is only a routing hint and can be reused after process exit.
    let auditToken: Data?

    init(identity: AppIdentity, applicationURL: URL, processIdentifier: Int32, auditToken: Data? = nil) {
        self.identity = identity
        self.applicationURL = applicationURL
        self.processIdentifier = processIdentifier
        self.auditToken = auditToken
    }
}

/// Capture in the application's synchronous URL handler, before creating a Task
/// or queuing work. Retain this value alongside the URL until the host is ready.
public struct AuthenticatedAppMessage: Sendable {
    public let url: URL
    public let sender: VerifiedApplication

    init(url: URL, sender: VerifiedApplication) { self.url = url; self.sender = sender }

    @MainActor public static func capture(_ url: URL) -> Self? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let token = AuthenticatedAppRouting.senderAuditToken(for: url, event: event),
              let sender = try? AuthenticatedAppRouting.verify(auditToken: token) else { return nil }
        return Self(url: url, sender: sender)
    }
}

/// LaunchServices carries public key-exchange hints; the original sender's
/// read-only Apple-event audit token independently authenticates each message.
/// No credentials are sent through this route.
@MainActor enum AuthenticatedAppRouting {
    static func inspect(applicationURL: URL, identity: AppIdentity) throws {
        guard applicationURL.isFileURL,
              applicationURL.pathExtension.lowercased() == "app",
              Bundle(url: applicationURL)?.bundleIdentifier == identity.bundleID else {
            throw TalkError.permissionDenied
        }
        let requirement = try requirement(for: identity)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess,
              try signingIdentity(of: code) == identity else { throw TalkError.permissionDenied }
    }

    static func launch(applicationURL: URL, identity: AppIdentity) async throws -> VerifiedApplication {
        try Task.checkCancellation()
        try inspect(applicationURL: applicationURL, identity: identity)
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleID)
        guard matches.count <= 1 else { throw TalkError.ambiguousProvider }
        if let running = matches.first {
            guard sameApplication(running.bundleURL, applicationURL) else { throw TalkError.ambiguousProvider }
            try await waitUntilLaunched(running)
            return try verify(running: running, identity: identity)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        let (stream, continuation) = AsyncThrowingStream<NSRunningApplication, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        defer { continuation.finish() }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { running, error in
            if let running, error == nil { continuation.yield(running); continuation.finish() }
            else { continuation.finish(throwing: TalkError.unavailable) }
        }
        let running = try await withDeadline(seconds: 15) {
            for try await application in stream { try Task.checkCancellation(); return application }
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard sameApplication(running.bundleURL, applicationURL),
              NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleID).count == 1 else {
            throw TalkError.ambiguousProvider
        }
        try await waitUntilLaunched(running)
        return try verify(running: running, identity: identity)
    }

    private static func waitUntilLaunched(_ application: NSRunningApplication) async throws {
        try await withDeadline(seconds: 15) {
            while !application.isFinishedLaunching {
                try Task.checkCancellation()
                guard !application.isTerminated else { throw TalkError.unavailable }
                try await DeadlineTimer.sleep(seconds: 0.05)
            }
        }
        try Task.checkCancellation()
    }

    static func send(_ url: URL, to application: VerifiedApplication) throws {
        guard url.absoluteString.utf8.count <= 8192,
              let running = NSRunningApplication(processIdentifier: application.processIdentifier),
              !running.isTerminated,
              sameApplication(running.bundleURL, application.applicationURL) else { throw TalkError.unavailable }
        // Refuse ambiguous copies, even at the same bundle path. The eventual
        // receiver still verifies the actual sender and pending request identity.
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: application.identity.bundleID)
        guard matches.count == 1, matches[0].processIdentifier == application.processIdentifier else {
            throw TalkError.ambiguousProvider
        }
        if let token = application.auditToken {
            let checked = try verify(auditToken: token)
            guard checked.identity == application.identity,
                  checked.processIdentifier == application.processIdentifier,
                  sameApplication(checked.applicationURL, application.applicationURL) else { throw TalkError.permissionDenied }
        } else {
            _ = try verify(running: running, identity: application.identity)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        // Direct kpid Apple events are blocked for sandbox senders. LaunchServices
        // preserves keySenderAuditTokenAttr for GURL, including sandbox senders.
        // keyActualSenderAuditToken names the forwarding system agent instead.
        NSWorkspace.shared.open([url], withApplicationAt: application.applicationURL, configuration: configuration) { _, _ in }
    }

    static func senderAuditToken(for url: URL, event: NSAppleEventDescriptor) -> Data? {
        guard url.absoluteString.utf8.count <= 8192,
              event.eventClass == AEEventClass(kInternetEventClass),
              event.eventID == AEEventID(kAEGetURL),
              event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue == url.absoluteString,
              let descriptor = event.attributeDescriptor(forKeyword: keySenderAuditTokenAttr),
              descriptor.descriptorType == typeAuditToken,
              descriptor.data.count == MemoryLayout<audit_token_t>.size else { return nil }
        return descriptor.data
    }

    static func requirement(for identity: AppIdentity) throws -> SecRequirement {
        guard PairingRouting.validBundleID(identity.bundleID),
              !identity.teamID.isEmpty, identity.teamID.utf8.count <= 64,
              identity.teamID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else {
            throw TalkError.permissionDenied
        }
        // Both strings are bounded ASCII allowlists, never requirement syntax.
        let expression = "anchor apple generic and identifier \"\(identity.bundleID)\" and certificate leaf[subject.OU] = \"\(identity.teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw TalkError.permissionDenied }
        return requirement
    }

    static func verify(auditToken: Data) throws -> VerifiedApplication {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { throw TalkError.permissionDenied }
        let token = auditToken.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        let pid = Int32(bitPattern: token.val.5)
        guard pid > 0,
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              let applicationURL = running.bundleURL else { throw TalkError.permissionDenied }
        let code = try dynamicCode(attributes: [kSecGuestAttributeAudit: auditToken])
        let identity = try validate(code: code, expected: nil)
        guard running.bundleIdentifier == identity.bundleID else { throw TalkError.permissionDenied }
        return VerifiedApplication(identity: identity, applicationURL: applicationURL,
                                   processIdentifier: pid, auditToken: auditToken)
    }

    private static func verify(running: NSRunningApplication, identity: AppIdentity) throws -> VerifiedApplication {
        guard !running.isTerminated, running.bundleIdentifier == identity.bundleID,
              let applicationURL = running.bundleURL else { throw TalkError.permissionDenied }
        let code = try dynamicCode(attributes: [kSecGuestAttributePid: running.processIdentifier])
        _ = try validate(code: code, expected: identity)
        return VerifiedApplication(identity: identity, applicationURL: applicationURL,
                                   processIdentifier: running.processIdentifier)
    }

    private static func dynamicCode(attributes: [CFString: Any]) throws -> SecCode {
        var attributes = attributes
        // Kernel-backed signing data avoids filesystem reads denied to a sandbox.
        // Dynamic validity and the certificate requirement remain mandatory below.
        attributes[kSecGuestAttributeDynamicCode] = true
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code else { throw TalkError.permissionDenied }
        return code
    }

    private static func validate(code: SecCode, expected: AppIdentity?) throws -> AppIdentity {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { throw TalkError.permissionDenied }
        let identity = try signingIdentity(of: staticCode)
        if let expected, identity != expected { throw TalkError.permissionDenied }
        guard SecCodeCheckValidity(code, [], try requirement(for: identity)) == errSecSuccess else {
            throw TalkError.permissionDenied
        }
        return identity
    }

    private static func signingIdentity(of code: SecStaticCode) throws -> AppIdentity {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw TalkError.permissionDenied
        }
        let identity = AppIdentity(bundleID: identifier, teamID: team)
        _ = try requirement(for: identity)
        return identity
    }

    private static func sameApplication(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }
}
