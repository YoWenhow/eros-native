import Foundation

public struct BlockImageEntry: Codable, Equatable, Identifiable, Sendable {
    public static let currentAlgorithmVersion = 1
    public let id: UUID
    public let owner: AccountID
    public let algorithmVersion: Int
    public let digest: String
    public let note: String?
    public let createdAt: Date
    public init(id: UUID = UUID(), owner: AccountID, algorithmVersion: Int = 1, digest: String,
                note: String? = nil, createdAt: Date = Date()) throws {
        let digest = digest.lowercased()
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard algorithmVersion == Self.currentAlgorithmVersion, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              (note?.utf8.count ?? 0) <= 1024, createdAt.timeIntervalSince1970.isFinite else { throw AppError.invalidInput }
        self.id = id; self.owner = owner; self.algorithmVersion = algorithmVersion
        self.digest = digest; self.note = note?.isEmpty == false ? note : nil; self.createdAt = createdAt
    }
    private enum CodingKeys: String, CodingKey { case id, owner, algorithmVersion, digest, note, createdAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), owner: c.decode(AccountID.self, forKey: .owner),
            algorithmVersion: c.decode(Int.self, forKey: .algorithmVersion), digest: c.decode(String.self, forKey: .digest),
            note: c.decodeIfPresent(String.self, forKey: .note), createdAt: c.decode(Date.self, forKey: .createdAt))
    }
}
