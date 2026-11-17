import CryptoKit
import Foundation

/// The file Hearth Spark hands to the iOS app — the *only* thing that leaves the Mac,
/// and only by the user sending it (AirDrop, Files).
///
/// Everything here is deliberately coarse. It carries what the phone needs to suggest a
/// person and a closeness tier, and nothing it doesn't:
///
/// - No message or call counts beyond what a reason sentence states.
/// - No exact dates: last contact is a month.
/// - No phone numbers or emails in the clear: only salted hashes, which the phone
///   recomputes from its own contacts to find the match.
/// - No one who isn't already in the user's Contacts.
///
/// Fields are added, never repurposed. Bump `version` on any change.
public struct SparkFile: Codable, Equatable, Sendable {
    public static let formatName = "hearth-spark"
    public static let currentVersion = 1

    public var format: String = SparkFile.formatName
    public var version: Int = SparkFile.currentVersion
    /// Month the file was made, "2026-11". A month, because nothing needs more.
    public var createdMonth: String
    /// Random per file, so the same number hashes differently in every file.
    public var salt: String
    public var people: [SparkPerson]

    public init(createdMonth: String, salt: String, people: [SparkPerson]) {
        self.createdMonth = createdMonth
        self.salt = salt
        self.people = people
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SparkFile {
        let file = try JSONDecoder().decode(SparkFile.self, from: data)
        guard file.format == formatName, file.version <= currentVersion else {
            throw SparkError.unsupportedFile
        }
        return file
    }
}

public struct SparkPerson: Codable, Equatable, Sendable {
    /// As written on the user's own contact card.
    public var name: String
    /// Salted hashes of the person's normalized phone numbers and emails.
    public var matchKeys: [String]
    public var suggestedTier: SparkTier
    /// "2026-10", or nil if Hearth Spark saw no messages or calls.
    public var lastContactMonth: String?
    /// Plain sentences shown to the user, strongest first.
    public var reasons: [String]

    public init(name: String, matchKeys: [String], suggestedTier: SparkTier, lastContactMonth: String?, reasons: [String]) {
        self.name = name
        self.matchKeys = matchKeys
        self.suggestedTier = suggestedTier
        self.lastContactMonth = lastContactMonth
        self.reasons = reasons
    }
}

/// Mirrors Hearth's `RelationshipTier`. The recommender never *suggests* "distant" —
/// people with that little signal are left out entirely — but the user can move
/// someone there in the review.
public enum SparkTier: String, Codable, Sendable, CaseIterable {
    case innerCircle, close, keptWarm, distant

    public var label: String {
        switch self {
        case .innerCircle: "Inner circle"
        case .close: "Close"
        case .keptWarm: "Kept warm"
        case .distant: "Distant"
        }
    }
}

public enum SparkError: LocalizedError, Equatable {
    case unsupportedFile

    public var errorDescription: String? {
        "This isn't a Hearth Spark file Hearth can read. Update Hearth and try again."
    }
}

public enum MatchKey {
    /// A fresh random salt, base64.
    public static func newSalt() -> String {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    /// SHA-256 of salt + normalized handle, hex.
    ///
    /// Honest about the limits: phone numbers are a small space, so anyone holding the
    /// file and the salt could recover a number by brute force. The hash keeps numbers
    /// out of plain sight in a file the user sends to their own phone; it is not
    /// anonymization, and the docs don't claim it is.
    public static func hash(_ normalizedHandle: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "|" + normalizedHandle).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
