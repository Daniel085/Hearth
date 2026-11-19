import Foundation

/// Turns counted interactions and contact cards into a Spark file.
///
/// Scoring is a transparent sum with a sentence for each part, so the user can see —
/// and disagree with — why someone was suggested. Weights favour effort and
/// reciprocity: a conversation that goes both ways counts; a stream of one-way
/// notifications from a business doesn't.
public struct Recommender {
    public var now: Date
    /// People below this score are left out of the file entirely.
    public var threshold = 4.0
    /// At most this many people. Hearth is for the few dozen who matter.
    public var limit = 150

    public init(now: Date = Date()) { self.now = now }

    public struct Scored: Equatable {
        public var card: ContactCard
        public var stats: HandleStats
        public var score: Double
        public var reasons: [String]
    }

    /// LinkedIn can add at most this much. It says who you worked with, not who you
    /// talk to, so it can lift someone but never outrank a real conversation.
    public static let linkedInCap = 6.0

    public func score(card: ContactCard, stats: HandleStats, linkedIn: LinkedInSuggestion? = nil) -> Scored {
        var total = 0.0
        var reasons: [(Double, String)] = []
        func add(_ points: Double, _ reason: String?) {
            guard points > 0 else { return }
            total += points
            if let reason { reasons.append((points, reason)) }
        }

        let twoWay = min(stats.sentLastYear, stats.receivedLastYear)
        if twoWay > 0 {
            // log2: the difference between 2 and 30 messages matters far more than
            // between 300 and 330. 255 two-way messages reaches the cap.
            add(min(8, log2(Double(1 + twoWay))),
                "Messaged both ways this past year (\(stats.sentLastYear) sent, \(stats.receivedLastYear) received)")
        }

        let twoWayEmail = min(stats.emailsSentLastYear, stats.emailsReceivedLastYear)
        if twoWayEmail > 0 {
            // Weighted below messages: email skews to work and logistics.
            add(min(5, log2(Double(1 + twoWayEmail))),
                "Emailed both ways this past year (\(stats.emailsSentLastYear) sent, \(stats.emailsReceivedLastYear) received)")
        }

        if stats.callsLastYear > 0 {
            let minutes = Int(stats.callMinutesLastYear.rounded())
            add(min(5, Double(stats.callsLastYear)) + min(3, stats.callMinutesLastYear / 30),
                stats.callsLastYear == 1
                    ? "1 call this past year" + (minutes > 0 ? " (\(minutes) min)" : "")
                    : "\(stats.callsLastYear) calls this past year" + (minutes > 0 ? " (\(minutes) min)" : ""))
        }

        let inTouch = twoWay > 0 || twoWayEmail > 0 || stats.callsLastYear > 0
        if let last = stats.last, inTouch {
            let days = now.timeIntervalSince(last) / 86_400
            add(days <= 30 ? 3 : days <= 90 ? 2 : days <= 365 ? 1 : 0, nil)
        }

        if let first = stats.first, inTouch,
           now.timeIntervalSince(first) >= 5 * 365 * 86_400 {
            add(2, "In touch since \(Calendar.current.component(.year, from: first))")
        }

        if let linkedIn, linkedIn.score > 0, !linkedIn.reasons.isEmpty {
            // Share the capped total across LinkedIn's own reasons, which arrive
            // strongest first, so they sort sensibly among the others.
            let share = min(Self.linkedInCap, linkedIn.score) / Double(linkedIn.reasons.count)
            for reason in linkedIn.reasons { add(share, "LinkedIn: \(reason)") }
        }

        if let relation = card.relation { add(4, "Your card lists them as \(relation)") }
        if card.hasBirthday { add(2, "Birthday saved") }
        if card.hasNickname { add(1, "Nickname saved") }
        if card.hasAddress { add(1, "Address saved") }

        return Scored(
            card: card, stats: stats, score: total,
            reasons: reasons.sorted { $0.0 > $1.0 }.map(\.1)
        )
    }

    public static func tier(for score: Double) -> SparkTier? {
        switch score {
        case 16...: .innerCircle
        case 9..<16: .close
        case 4..<9: .keptWarm
        default: nil
        }
    }

    public struct Result {
        public var file: SparkFile
        public var scored: [Scored]
        /// Handles with messages or calls that matched no contact: dropped, and only
        /// ever reported as a count.
        public var unmatchedHandles: Int
    }

    /// Joins interactions to contacts, scores, and builds the file.
    ///
    /// Interactions with numbers not in Contacts are discarded here — strangers,
    /// businesses, two-factor codes. They are never scored, named or sent.
    public func build(
        cards: [ContactCard],
        interactions: [String: HandleStats],
        linkedIn: [Int: LinkedInSuggestion] = [:],
        salt: String = MatchKey.newSalt()
    ) -> Result {
        var owner: [String: Int] = [:]
        for (index, card) in cards.enumerated() {
            for handle in card.handles where owner[handle] == nil { owner[handle] = index }
        }
        let unmatched = interactions.keys.filter { owner[$0] == nil }.count

        var scored: [Scored] = []
        for (index, card) in cards.enumerated() {
            var stats = HandleStats()
            for handle in card.handles { if let s = interactions[handle] { stats.merge(s) } }
            let result = score(card: card, stats: stats, linkedIn: linkedIn[index])
            if result.score >= threshold { scored.append(result) }
        }
        scored.sort { $0.score > $1.score }
        scored = Array(scored.prefix(limit))

        let people = scored.map { s in
            SparkPerson(
                name: s.card.name,
                matchKeys: s.card.handles.map { MatchKey.hash($0, salt: salt) }.sorted(),
                suggestedTier: Self.tier(for: s.score) ?? .keptWarm,
                lastContactMonth: s.stats.last.map(Self.month),
                reasons: s.reasons
            )
        }
        return Result(
            file: SparkFile(createdMonth: Self.month(now), salt: salt, people: people),
            scored: scored,
            unmatchedHandles: unmatched
        )
    }

    static func month(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
