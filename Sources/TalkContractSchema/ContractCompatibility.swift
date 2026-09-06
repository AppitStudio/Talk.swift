import Foundation

/// Directional wire compatibility. This does not infer application semantics or
/// validate runtime payloads; both schemas must pass schema validation first.
public enum ContractCompatibility {
    public static func diagnostics(client: ContractSchema, provider: ContractSchema,
                                   requiredActions: Set<String>? = nil,
                                   requiredEvents: Set<String>? = nil,
                                   minimumMinor: Int = 0) throws -> [ContractDiagnostic] {
        try client.validate(); try provider.validate()
        var issues: [ContractDiagnostic] = []
        func report(_ path: String, _ message: String) { issues.append(ContractDiagnostic("\(path): \(message)")) }
        let cv = client.contractVersion.split(separator: ".")
        let pv = provider.contractVersion.split(separator: ".")
        if client.contractID != provider.contractID { report("contractID", "different contract") }
        if cv[0] != pv[0] { report("contractVersion", "incompatible major \(provider.contractVersion); client expects \(cv[0])") }
        if minimumMinor < 0 || (Int(pv[1]) ?? -1) < minimumMinor { report("contractVersion", "provider minor is below required \(minimumMinor)") }
        let ct = Dictionary(uniqueKeysWithValues: client.types.map { ($0.name, $0) })
        let pt = Dictionary(uniqueKeysWithValues: provider.types.map { ($0.name, $0) })
        var comparisons = 0
        func accepts(_ sent: String, _ received: String, _ st: [String: ContractSchema.DTO],
                     _ rt: [String: ContractSchema.DTO], _ path: String) {
            comparisons += 1
            guard comparisons <= 4096 else {
                if comparisons == 4097 { report(path, "compatibility complexity limit exceeded") }
                return
            }
            if received.hasSuffix("?") {
                accepts(sent.hasSuffix("?") ? String(sent.dropLast()) : sent, String(received.dropLast()), st, rt, path)
                return
            }
            if sent.hasSuffix("?") { report(path, "sender may omit/null a required value"); return }
            if sent.hasPrefix("["), received.hasPrefix("[") {
                accepts(String(sent.dropFirst().dropLast()), String(received.dropFirst().dropLast()), st, rt, path + "[]")
                return
            }
            guard let source = st[sent], let target = rt[received] else {
                if sent != received { report(path, "wire type \(sent) cannot be decoded as \(received)") }
                return
            }
            guard source.kind == target.kind else { report(path, "DTO kind changed"); return }
            if source.kind == "enum" {
                let unknown = Set(source.cases ?? []).subtracting(target.cases ?? []).sorted()
                if !unknown.isEmpty { report(path, "receiver does not accept enum cases: " + unknown.joined(separator: ", ")) }
            } else {
                let fields = Dictionary(uniqueKeysWithValues: (source.fields ?? []).map { ($0.name, $0.type) })
                for field in target.fields ?? [] {
                    if let type = fields[field.name] { accepts(type, field.type, st, rt, path + "." + field.name) }
                    else if !field.type.hasSuffix("?") { report(path + "." + field.name, "required field is absent from sender") }
                }
            }
        }
        let ca = Dictionary(uniqueKeysWithValues: client.actions.map { ($0.id, $0) })
        let pa = Dictionary(uniqueKeysWithValues: provider.actions.map { ($0.id, $0) })
        for id in (requiredActions ?? Set(ca.keys)).sorted() {
            guard let expected = ca[id] else { report(id, "required capability absent from client schema"); continue }
            guard let actual = pa[id] else { report(id, "required action unavailable on provider"); continue }
            if expected.scope != actual.scope { report(id + ".scope", "permission meaning changed") }
            if expected.mutation != actual.mutation { report(id + ".mutation", "mutation classification changed") }
            accepts(expected.input, actual.input, ct, pt, id + ".input")
            accepts(actual.output, expected.output, pt, ct, id + ".output")
        }
        let ce = Dictionary(uniqueKeysWithValues: client.events.map { ($0.id, $0) })
        let pe = Dictionary(uniqueKeysWithValues: provider.events.map { ($0.id, $0) })
        for id in (requiredEvents ?? Set(ce.keys)).sorted() {
            guard let expected = ce[id] else { report(id, "required event absent from client schema"); continue }
            guard let actual = pe[id] else { report(id, "required event unavailable on provider"); continue }
            accepts(actual.payload, expected.payload, pt, ct, id + ".event")
        }
        return issues
    }
}
