import Foundation

public enum LocalRuleKind: String, Codable, CaseIterable, Sendable {
    case tag, uploader, category, language
}

public struct LocalDisplayRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let account: AccountID
    public let version: Int
    public let createdAt: Date
    public let enabled: Bool
    public let kind: LocalRuleKind
    public let namespace: String?
    public let value: String

    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    public init(id: UUID = UUID(), account: AccountID, version: Int = 1, createdAt: Date = Date(),
                enabled: Bool = true, kind: LocalRuleKind, namespace: String? = nil, value: String) throws {
        let value = Self.normalized(value)
        let ns = namespace.map { Self.normalized($0) }
        guard version > 0, version < Int.max, createdAt.timeIntervalSince1970.isFinite, !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw AppError.invalidInput }
        if kind == .tag {
            guard let ns, (try? TagTranslationKey(namespace: ns, original: value)) != nil else { throw AppError.invalidInput }
        } else if ns != nil { throw AppError.invalidInput }
        self.id = id; self.account = account; self.version = version; self.createdAt = createdAt
        self.enabled = enabled; self.kind = kind; self.namespace = ns; self.value = value
    }
    private enum CodingKeys: String, CodingKey { case id, account, version, createdAt, enabled, kind, namespace, value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), account: c.decode(AccountID.self, forKey: .account),
                      version: c.decode(Int.self, forKey: .version), createdAt: c.decode(Date.self, forKey: .createdAt),
                      enabled: c.decode(Bool.self, forKey: .enabled), kind: c.decode(LocalRuleKind.self, forKey: .kind),
                      namespace: c.decodeIfPresent(String.self, forKey: .namespace), value: c.decode(String.self, forKey: .value))
    }
}

public struct LocalRuleDecision: Equatable, Sendable {
    public let matches: [LocalDisplayRule]
    public let hasUnknown: Bool
    public var hidden: Bool { !matches.isEmpty }
}

public enum LocalRuleEvaluator {
    /// List tags can be truncated. Only a detail response can prove a missing tag does not match.
    public static func evaluate(_ summary: GallerySummary, rules: [LocalDisplayRule], account: AccountID,
                                completeTags: [TagGroup]? = nil) -> LocalRuleDecision {
        var hits: [LocalDisplayRule] = []
        var unknown = false
        for rule in rules where rule.enabled && rule.account == account {
            let matched: Bool?
            switch rule.kind {
            case .uploader: matched = summary.uploader.map { LocalDisplayRule.normalized($0) == rule.value }
            case .category: matched = summary.category.map { LocalDisplayRule.normalized($0) == rule.value }
            case .tag, .language:
                let namespace = rule.kind == .language ? "language" : rule.namespace!
                let groups = completeTags ?? summary.listTags ?? []
                let hit = groups.contains { group in
                    group.namespace.map(LocalDisplayRule.normalized) == namespace &&
                        group.tags.contains { LocalDisplayRule.normalized($0) == rule.value }
                }
                matched = hit ? true : (completeTags == nil ? nil : false)
            }
            if matched == true { hits.append(rule) }
            if matched == nil { unknown = true }
        }
        return LocalRuleDecision(matches: hits, hasUnknown: unknown)
    }
}

/// Limits a run of fully hidden pages without consuming or changing the server cursor.
public struct HiddenPageBudget: Sendable {
    public private(set) var batches = 0
    public init() {}
    public mutating func reset() { batches = 0 }
    public mutating func consume(allHidden: Bool, hasNext: Bool) -> Bool {
        guard allHidden, hasNext, batches < 3 else { return false }
        batches += 1
        return true
    }
}
