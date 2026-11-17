import Foundation

/// The optional sources the user can switch on or off. Contacts isn't one of them:
/// without it every number is a stranger and nothing can be suggested.
public enum SparkSource: String, CaseIterable, Hashable, Sendable {
    case messages, calls, mail

    public var name: String {
        switch self {
        case .messages: "Messages"
        case .calls: "Call history"
        case .mail: "Mail"
        }
    }

    /// What reading it means, in the user's terms.
    public var blurb: String {
        switch self {
        case .messages: "Who you text and iMessage one-to-one, and when."
        case .calls: "Who you call and FaceTime, when, and for how long."
        case .mail: "Who you email in Apple Mail, and when. Small emails only — no lists or newsletters."
        }
    }

    func read(now: Date) throws -> [String: HandleStats] {
        switch self {
        case .messages: try MessagesSource.read(now: now)
        case .calls: try CallsSource.read(now: now)
        case .mail: try MailSource.read(now: now)
        }
    }
}

/// One complete run: read Contacts and the chosen sources, score, and build the file.
///
/// Shared by the command-line tool and the app so both read exactly the same things.
/// The result lives in memory only; nothing here touches the disk except to read.
public struct SparkScan {
    public var cardCount: Int
    public var interactionHandles: Int
    public var reports: [Review.SourceReport]
    public var result: Recommender.Result

    /// Throws only if Contacts can't be read. A source that's switched off is never
    /// opened; one that can't be read is skipped. Both are noted in `reports`.
    public static func run(sources enabled: Set<SparkSource> = Set(SparkSource.allCases), now: Date = Date()) throws -> SparkScan {
        let cards = try ContactsSource.read()
        let (interactions, sourceReports) = gather(enabled) { try $0.read(now: now) }
        return SparkScan(
            cardCount: cards.count,
            interactionHandles: interactions.count,
            reports: [
                .init(name: "Contacts", detail: "\(cards.count) cards — names, numbers, emails, and whether a birthday, address, nickname or relation is filled in. Your own card is skipped."),
            ] + sourceReports,
            result: Recommender(now: now).build(cards: cards, interactions: interactions)
        )
    }

    /// Reads each enabled source and merges the counts. `read` is never called for a
    /// source that's switched off.
    static func gather(
        _ enabled: Set<SparkSource>,
        read: (SparkSource) throws -> [String: HandleStats]
    ) -> ([String: HandleStats], [Review.SourceReport]) {
        var interactions: [String: HandleStats] = [:]
        var reports: [Review.SourceReport] = []
        for source in SparkSource.allCases {
            guard enabled.contains(source) else {
                reports.append(.init(name: source.name, detail: "Switched off, so it was never opened.", skipped: true))
                continue
            }
            do {
                let stats = try read(source)
                for (handle, s) in stats { interactions[handle, default: HandleStats()].merge(s) }
                reports.append(.init(name: source.name, detail: "who and when, counted per person, for \(stats.count) numbers/emails"))
            } catch {
                reports.append(.init(name: source.name, detail: error.localizedDescription, skipped: true))
            }
        }
        return (interactions, reports)
    }
}

extension SparkFile {
    /// The file as the user left it in the review: only the ticked people, at the
    /// closeness the user chose. Unticking someone removes them from what's sent, not
    /// just from view; changing a tier changes what's sent, not just the label.
    public func reviewed(keeping indices: Set<Int>, tiers: [Int: SparkTier] = [:]) -> SparkFile {
        var copy = self
        copy.people = people.enumerated().compactMap { index, person in
            guard indices.contains(index) else { return nil }
            var person = person
            if let tier = tiers[index] { person.suggestedTier = tier }
            return person
        }
        return copy
    }
}

/// Checks for the permissions Hearth Spark needs, without asking for them.
public enum Permissions {
    /// Full Disk Access can't be queried directly; the honest test is whether a
    /// protected file actually opens.
    public static var hasFullDiskAccess: Bool {
        for path in [MessagesSource.defaultPath, CallsSource.defaultPath] {
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return true
            }
        }
        return false
    }
}
