import Foundation
import Network
import Security

enum TLSConfiguration {
    static func parameters(credential: PairingCredential, isServer: Bool = false) throws -> NWParameters {
        try credential.validate()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, "talk-spike/1")
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_peer_authentication_required(options, true)
        let localRole: PairedTLSIdentity.Role = isServer ? .server : .client
        let peerRole: PairedTLSIdentity.Role = isServer ? .client : .server
        sec_protocol_options_set_local_identity(options, try PairedTLSIdentity.make(credential: credential, role: localRole))
        let expected = try PairedTLSIdentity.key(credential: credential, role: peerRole).publicKey.x963Representation
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            complete(PairedTLSIdentity.verify(sec_trust_copy_ref(trust).takeRetainedValue(), expectedPublicKey: expected))
        }, .global(qos: .utility))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        return parameters
    }
}
