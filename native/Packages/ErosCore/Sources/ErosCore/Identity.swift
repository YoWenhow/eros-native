import Foundation

/// Custom decoding must go through validation, not synthesized member assignment.
public protocol ValidatedValue: Codable, Hashable, Sendable {
    associatedtype Value: Codable & Hashable & Sendable
    var value: Value { get }
    init(_ value: Value) throws
}
extension ValidatedValue {
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Value.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
public struct GalleryID: ValidatedValue {
    public let value: Int64
    public init(_ value: Int64) throws {
        guard value > 0 else { throw AppError.invalidInput }
        self.value = value
    }
}
public struct PageIndex: ValidatedValue, Comparable {
    public let value: Int
    public init(_ value: Int) throws {
        guard value >= 0 && value < Int.max else { throw AppError.invalidInput }
        self.value = value
    }
    public init(displayNumber: Int, pageCount: Int) throws {
        guard displayNumber > 0 && displayNumber <= pageCount else { throw AppError.invalidInput }
        try self.init(displayNumber - 1)
    }
    public var displayNumber: Int { value + 1 }
    public func checked(pageCount: Int) throws -> Self {
        guard value < pageCount else { throw AppError.invalidInput }
        return self
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}
public struct NonnegativeCount: ValidatedValue {
    public let value: Int
    public init(_ value: Int) throws {
        guard value >= 0 else { throw AppError.invalidInput }
        self.value = value
    }
}
public struct UnitFraction: ValidatedValue {
    public let value: Double
    public init(_ value: Double) throws {
        guard value.isFinite && (0...1).contains(value) else { throw AppError.invalidInput }
        self.value = value
    }
}
/// Raw values are for adapters/persistence only, never diagnostics.
public struct SensitiveText: ValidatedValue, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty else { throw AppError.invalidInput }
        self.value = value
    }
    public var description: String { "<redacted>" }
    public var debugDescription: String { description }
}
public struct RelativePath: ValidatedValue {
    public let value: String
    public init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.contains(":"), !value.contains("%"), !value.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw AppError.invalidInput }
        self.value = value
    }
}
public enum Site: String, Codable, Hashable, Sendable { case eh, ex }
public struct AccountID: Codable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}
/// Stable storage partition. A returning account retains data across session generations.
public struct StorageScope: Codable, Hashable, Sendable {
    public let accountID: AccountID
    public let site: Site
    public init(accountID: AccountID, site: Site) { self.accountID = accountID; self.site = site }
}
public struct SessionScope: Codable, Hashable, Sendable {
    public let storage: StorageScope
    public let generation: UInt64
    public init(storage: StorageScope, generation: UInt64) {
        self.storage = storage; self.generation = generation
    }
    public func advanced() throws -> Self {
        guard generation < UInt64.max else { throw AppError.invalidInput }
        return Self(storage: storage, generation: generation + 1)
    }
}
public struct GalleryKey: Codable, Hashable, Sendable {
    public let site: Site
    public let galleryID: GalleryID
    public init(site: Site, galleryID: GalleryID) { self.site = site; self.galleryID = galleryID }
}
public struct GalleryReference: Codable, Hashable, Sendable {
    public let key: GalleryKey
    public let token: SensitiveText
    public init(key: GalleryKey, token: SensitiveText) { self.key = key; self.token = token }
    public func onSite(_ site: Site) -> Self {
        Self(key: GalleryKey(site: site, galleryID: key.galleryID), token: token)
    }
    public func validate(scope: SessionScope) throws {
        guard key.site == scope.storage.site else { throw AppError.scopeMismatch }
    }
}
