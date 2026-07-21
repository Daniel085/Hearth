import Foundation

/// The Launchpad scoring model from `docs/data-model.md` §4.
///
/// Deliberately free of Core Data and of the system clock: everything takes plain values
/// and an explicit `now`. That makes every rule testable without a database or a device,
/// and makes "what happens 3 days before a birthday" a test rather than a guess.

// MARK: - Inputs

/// How close someone is, set by the user rather than inferred.
///
/// Photo frequency is a poor proxy for closeness — you photograph a wedding you attended
/// once far more than a sibling you call weekly. Signals drive *timing*; the user sets
/// *ranking*. See `docs/data-model.md` §4.1.
enum RelationshipTier: Int16, CaseIterable, Sendable {
    case innerCircle = 0
    case close = 1
    case keptWarm = 2
    case distant = 3

    /// Expected days between contact, absent a user override.
    var defaultCadenceDays: Int {
        switch self {
        case .innerCircle: 7
        case .close: 30
        case .keptWarm: 90
        case .distant: 365
        }
    }

    var label: String {
        switch self {
        case .innerCircle: "Inner circle"
        case .close: "Close"
        case .keptWarm: "Kept warm"
        case .distant: "Distant"
        }
    }
}

/// Everything the scorer needs about one person. A flat snapshot, assembled by the caller.
struct ScoringInput: Sendable {
    var personID: UUID
    var displayName: String
    var tier: RelationshipTier

    /// User override for expected contact interval. Nil uses the tier default.
    var cadenceTargetDays: Int?

    /// Last time contact was *observed*. Not the same as the last time contact happened —
    /// iOS exposes no call or message history, so this is only what Hearth could see.
    var lastInteraction: Date?

    var birthday: Date?

    /// Start of a shared calendar event, if one is coming up.
    var upcomingEventDate: Date?
    var upcomingEventTitle: String?

    /// True when the device is currently inside a place associated with this person.
    var isNearAssociatedPlace: Bool = false
    var nearbyPlaceName: String?

    /// How many times this person has appeared on the Launchpad without being acted on.
    var unactionedAppearances: Int = 0

    var isMuted: Bool = false

    var cadenceDays: Int {
        cadenceTargetDays ?? tier.defaultCadenceDays
    }
}

// MARK: - Output

/// Why a person surfaced. Each card shows these, so the reasons must be human-readable.
struct ScoredPerson: Sendable, Identifiable {
    var id: UUID { personID }
    let personID: UUID
    let displayName: String
    let score: Double
    let reasons: [Reason]

    struct Reason: Sendable, Hashable {
        let kind: Kind
        let text: String
        let contribution: Double

        enum Kind: Sendable, Hashable {
            case overdue, birthday, upcomingEvent, nearbyPlace, recentlyContacted, fatigue
        }
    }

    /// The single line shown on the card.
    ///
    /// Chosen by *specificity*, not by score contribution. Picking the largest number
    /// produced cards saying "No contact noted in 4 months" for someone you are standing
    /// next to right now — technically the bigger term, but far less useful and slightly
    /// absurd. A time-and-place-specific reason always beats a general one.
    ///
    /// Ordering: nearby > birthday > upcoming event > overdue. The negative terms
    /// (recently contacted, fatigue) explain a *low* score and are never a headline.
    var headline: String? {
        let priority: [Reason.Kind] = [.nearbyPlace, .birthday, .upcomingEvent, .overdue]
        for kind in priority {
            if let reason = reasons.first(where: { $0.kind == kind && $0.contribution > 0 }) {
                return reason.text
            }
        }
        return nil
    }

    /// Secondary reasons, for a card that wants to show more than the headline.
    var supportingReasons: [Reason] {
        let headlineText = headline
        return reasons.filter { $0.contribution > 0 && $0.text != headlineText }
    }
}

// MARK: - Weights

struct ScoringWeights: Sendable {
    var cadence: Double = 1.0
    var birthday: Double = 2.5
    var calendar: Double = 2.0
    var place: Double = 1.5
    var recentlyContacted: Double = 3.0
    var fatigue: Double = 0.35

    static let `default` = ScoringWeights()
}

// MARK: - Scorer

struct RelationshipScorer: Sendable {
    var weights: ScoringWeights

    init(weights: ScoringWeights = .default) {
        self.weights = weights
    }

    /// Scores and ranks, dropping muted people and anyone with no reason to surface.
    func rank(_ inputs: [ScoringInput], now: Date, calendar: Calendar = .current) -> [ScoredPerson] {
        inputs
            .filter { !$0.isMuted }
            .map { score($0, now: now, calendar: calendar) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
    }

    func score(_ input: ScoringInput, now: Date, calendar: Calendar = .current) -> ScoredPerson {
        var reasons: [ScoredPerson.Reason] = []
        var total = 0.0

        func add(_ kind: ScoredPerson.Reason.Kind, _ text: String, _ value: Double) {
            guard value != 0 else { return }
            reasons.append(.init(kind: kind, text: text, contribution: value))
            total += value
        }

        // Overdue contact.
        if let ratio = overdueRatio(input, now: now) {
            add(.overdue, overdueText(input, now: now, calendar: calendar), weights.cadence * ratio)
        }

        // Birthday.
        if let days = daysUntilBirthday(input, now: now, calendar: calendar),
           let spike = birthdayProximity(daysAway: days) {
            add(.birthday, birthdayText(input, daysAway: days), weights.birthday * spike)
        }

        // Upcoming shared event.
        if let eventDate = input.upcomingEventDate {
            let daysAway = calendar.dateComponents([.day], from: now, to: eventDate).day ?? 0
            if daysAway >= 0 && daysAway <= 7 {
                // Sooner is more useful — you can still act on it.
                let proximity = 1.0 - (Double(daysAway) / 8.0)
                add(.upcomingEvent, eventText(input, daysAway: daysAway), weights.calendar * proximity)
            }
        }

        // Physically nearby a shared place.
        if input.isNearAssociatedPlace {
            let place = input.nearbyPlaceName.map { " near \($0)" } ?? " nearby"
            add(.nearbyPlace, "You're\(place)", weights.place)
        }

        // Recently contacted — strong suppression, so we don't nag about someone just called.
        if let last = input.lastInteraction {
            let hours = now.timeIntervalSince(last) / 3600
            if hours < 48 {
                let recency = 1.0 - (hours / 48.0)
                add(.recentlyContacted, "You were in touch recently", -weights.recentlyContacted * recency)
            }
        }

        // Fatigue. Without this the same few people pin to the top forever and the
        // Launchpad becomes wallpaper the user learns to ignore.
        if input.unactionedAppearances > 0 {
            let decay = min(Double(input.unactionedAppearances), 6.0)
            add(.fatigue, "Shown recently without action", -weights.fatigue * decay)
        }

        return ScoredPerson(
            personID: input.personID,
            displayName: input.displayName,
            score: max(0, total),
            reasons: reasons
        )
    }

    // MARK: Components

    /// Days overdue relative to this person's expected cadence, clamped to [0, 2].
    ///
    /// The clamp matters: without it, someone unseen for five years permanently occupies
    /// the top slot and the Launchpad stops feeling alive. Capping at 2× means
    /// "very overdue" saturates and other signals can still win.
    func overdueRatio(_ input: ScoringInput, now: Date) -> Double? {
        guard input.cadenceDays > 0 else { return nil }

        // Never-contacted people are treated as exactly due, not infinitely overdue.
        // Otherwise every newly-found face outranks real relationships on day one.
        guard let last = input.lastInteraction else { return 1.0 }

        let days = now.timeIntervalSince(last) / 86_400
        guard days > 0 else { return nil }
        return min(max(days / Double(input.cadenceDays), 0), 2.0)
    }

    /// Birthday spike: zero beyond 14 days, rising sharply inside 3.
    func birthdayProximity(daysAway: Int) -> Double? {
        guard daysAway >= 0, daysAway <= 14 else { return nil }
        if daysAway <= 3 { return 1.0 }
        // Linear falloff from 1.0 at day 3 to ~0 at day 14.
        return max(0, 1.0 - Double(daysAway - 3) / 11.0)
    }

    /// Days until the *next* occurrence of the birthday, ignoring birth year.
    func daysUntilBirthday(_ input: ScoringInput, now: Date, calendar: Calendar) -> Int? {
        guard let birthday = input.birthday else { return nil }

        let components = calendar.dateComponents([.month, .day], from: birthday)
        guard let month = components.month, let day = components.day else { return nil }

        let today = calendar.startOfDay(for: now)
        let thisYear = calendar.component(.year, from: today)

        // Try this year, then next — handles the December-to-January wrap.
        for year in [thisYear, thisYear + 1] {
            var next = DateComponents()
            next.year = year
            next.month = month
            next.day = day
            guard let date = calendar.date(from: next) else { continue }
            let start = calendar.startOfDay(for: date)
            if start >= today {
                return calendar.dateComponents([.day], from: today, to: start).day
            }
        }
        return nil
    }

    // MARK: Copy

    private func overdueText(_ input: ScoringInput, now: Date, calendar: Calendar) -> String {
        guard let last = input.lastInteraction else {
            return "You haven't connected yet"
        }
        let days = Int(now.timeIntervalSince(last) / 86_400)

        // Hedged deliberately. iOS exposes no call or message history, so Hearth knows
        // when it last *noticed* contact, not when contact last happened. Saying "you
        // haven't spoken in 3 months" to someone who calls their mother weekly would
        // destroy trust in the whole surface.
        switch days {
        case ..<14: return "No contact noted in \(days) days"
        case ..<60: return "No contact noted in \(days / 7) weeks"
        case ..<365: return "No contact noted in \(days / 30) months"
        default: return "No contact noted in over a year"
        }
    }

    private func birthdayText(_ input: ScoringInput, daysAway: Int) -> String {
        let first = input.displayName.split(separator: " ").first.map(String.init)
            ?? input.displayName
        switch daysAway {
        case 0: return "\(first)'s birthday is today"
        case 1: return "\(first)'s birthday is tomorrow"
        default: return "\(first)'s birthday is in \(daysAway) days"
        }
    }

    private func eventText(_ input: ScoringInput, daysAway: Int) -> String {
        let title = input.upcomingEventTitle ?? "You have plans"
        switch daysAway {
        case 0: return "\(title) — today"
        case 1: return "\(title) — tomorrow"
        default: return "\(title) — in \(daysAway) days"
        }
    }
}
