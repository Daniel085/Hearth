import Testing
import Foundation
@testable import Hearth

// A fixed "now" so every test is deterministic — no dependence on the real clock.
private let now = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15 ~14:26 UTC
// `let`, not `var` — a mutable global is not concurrency-safe under Swift 6, and tests
// run in parallel.
private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
private func daysAhead(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

private func person(
    name: String = "Sam",
    tier: RelationshipTier = .close,
    cadence: Int? = nil,
    last: Date? = nil,
    birthday: Date? = nil,
    event: Date? = nil,
    eventTitle: String? = nil,
    nearPlace: Bool = false,
    unactioned: Int = 0,
    muted: Bool = false
) -> ScoringInput {
    ScoringInput(
        personID: UUID(), displayName: name, tier: tier,
        cadenceTargetDays: cadence, lastInteraction: last, birthday: birthday,
        upcomingEventDate: event, upcomingEventTitle: eventTitle,
        isNearAssociatedPlace: nearPlace, nearbyPlaceName: nearPlace ? "Joe's Coffee" : nil,
        unactionedAppearances: unactioned, isMuted: muted
    )
}

// MARK: - Cadence

@Test("Someone overdue relative to their tier scores above someone on schedule")
func overdueOutranksOnSchedule() {
    let scorer = RelationshipScorer()
    let overdue = scorer.score(person(tier: .close, last: daysAgo(90)), now: now, calendar: cal)
    let onTime = scorer.score(person(tier: .close, last: daysAgo(5)), now: now, calendar: cal)
    #expect(overdue.score > onTime.score)
}

@Test("Overdue ratio is clamped so ancient contacts don't monopolise the top")
func overdueIsClamped() {
    let scorer = RelationshipScorer()
    let fiveYears = scorer.overdueRatio(person(tier: .close, last: daysAgo(1825)), now: now)
    let twoMonths = scorer.overdueRatio(person(tier: .close, last: daysAgo(60)), now: now)
    #expect(fiveYears == 2.0)
    #expect(twoMonths == 2.0)
    // Both saturate — neither can outgrow the other without bound.
    #expect(fiveYears == twoMonths)
}

@Test("A never-contacted person is treated as due, not infinitely overdue")
func neverContactedIsMerelyDue() {
    let scorer = RelationshipScorer()
    // Otherwise every newly-discovered face outranks real relationships on day one.
    #expect(scorer.overdueRatio(person(last: nil), now: now) == 1.0)
}

@Test("Tier changes the cadence a person is measured against")
func tierSetsCadence() {
    let scorer = RelationshipScorer()
    // 20 days: overdue for inner circle (7d), well within cadence for kept-warm (90d).
    let inner = scorer.score(person(tier: .innerCircle, last: daysAgo(20)), now: now, calendar: cal)
    let warm = scorer.score(person(tier: .keptWarm, last: daysAgo(20)), now: now, calendar: cal)
    #expect(inner.score > warm.score)
}

@Test("A user cadence override wins over the tier default")
func cadenceOverrideApplies() {
    let scorer = RelationshipScorer()
    let ratio = scorer.overdueRatio(person(tier: .distant, cadence: 7, last: daysAgo(14)), now: now)
    #expect(ratio == 2.0)  // 14 days against a 7-day target, clamped
}

// MARK: - Birthdays

@Test("Birthday spike is full strength within three days and zero beyond fourteen")
func birthdayWindow() {
    let scorer = RelationshipScorer()
    #expect(scorer.birthdayProximity(daysAway: 0) == 1.0)
    #expect(scorer.birthdayProximity(daysAway: 3) == 1.0)
    #expect(scorer.birthdayProximity(daysAway: 14) != nil)
    #expect(scorer.birthdayProximity(daysAway: 15) == nil)
    #expect(scorer.birthdayProximity(daysAway: -1) == nil)

    let near = scorer.birthdayProximity(daysAway: 5) ?? 0
    let far = scorer.birthdayProximity(daysAway: 12) ?? 0
    #expect(near > far)
}

@Test("Birthday is computed for the next occurrence, ignoring birth year")
func birthdayIgnoresBirthYear() {
    let scorer = RelationshipScorer()
    // Born in 1985; the next occurrence is what matters.
    var c = DateComponents(); c.year = 1985; c.month = 6; c.day = 20
    let birthday = cal.date(from: c)!
    let days = scorer.daysUntilBirthday(person(birthday: birthday), now: now, calendar: cal)
    #expect(days == 5, "expected 5 days, got \(String(describing: days))")
}

@Test("A birthday just past rolls to next year rather than going negative")
func birthdayWrapsToNextYear() {
    let scorer = RelationshipScorer()
    // 10 June is behind 15 June — must roll forward, not report -5.
    var c = DateComponents(); c.year = 1990; c.month = 6; c.day = 10
    let birthday = cal.date(from: c)!
    let days = scorer.daysUntilBirthday(person(birthday: birthday), now: now, calendar: cal)
    #expect(days != nil)
    #expect(days! > 300, "expected next year, got \(days!)")
}

@Test("December birthdays wrap correctly when scored in January")
func decemberBirthdayFromJanuary() {
    let scorer = RelationshipScorer()
    var janC = DateComponents(); janC.year = 2026; janC.month = 1; janC.day = 5
    let january = cal.date(from: janC)!

    var bC = DateComponents(); bC.year = 1980; bC.month = 12; bC.day = 25
    let birthday = cal.date(from: bC)!

    let days = scorer.daysUntilBirthday(person(birthday: birthday), now: january, calendar: cal)
    #expect(days != nil)
    // 5 Jan to 25 Dec of the same year — must not be negative.
    #expect(days! > 300, "expected ~354, got \(days!)")
}

// MARK: - Suppression

@Test("Someone contacted in the last 48 hours is suppressed")
func recentContactSuppresses() {
    let scorer = RelationshipScorer()
    // Very overdue on paper, but contact was noted an hour ago.
    let justCalled = scorer.score(
        person(tier: .innerCircle, last: now.addingTimeInterval(-3600)), now: now, calendar: cal
    )
    #expect(justCalled.score == 0, "score was \(justCalled.score)")
}

@Test("Fatigue decays a person shown repeatedly without action")
func fatigueDecays() {
    let scorer = RelationshipScorer()
    let fresh = scorer.score(person(tier: .close, last: daysAgo(60), unactioned: 0), now: now, calendar: cal)
    let stale = scorer.score(person(tier: .close, last: daysAgo(60), unactioned: 5), now: now, calendar: cal)
    #expect(stale.score < fresh.score)
}

@Test("Fatigue is capped so it cannot bury someone permanently")
func fatigueIsCapped() {
    let scorer = RelationshipScorer()
    let six = scorer.score(person(tier: .close, last: daysAgo(60), unactioned: 6), now: now, calendar: cal)
    let fifty = scorer.score(person(tier: .close, last: daysAgo(60), unactioned: 50), now: now, calendar: cal)
    #expect(six.score == fifty.score)
}

@Test("Muted people never appear")
func mutedExcluded() {
    let scorer = RelationshipScorer()
    let ranked = scorer.rank(
        [person(name: "Muted", last: daysAgo(400), muted: true),
         person(name: "Visible", last: daysAgo(60))],
        now: now, calendar: cal
    )
    #expect(ranked.count == 1)
    #expect(ranked.first?.displayName == "Visible")
}

// MARK: - Reasons

@Test("Every surfaced person carries an explanation")
func everyoneHasAReason() {
    let scorer = RelationshipScorer()
    var c = DateComponents(); c.year = 1985; c.month = 6; c.day = 17
    let ranked = scorer.rank(
        [person(name: "Overdue", last: daysAgo(120)),
         person(name: "Birthday", last: daysAgo(10), birthday: cal.date(from: c)!),
         person(name: "Nearby", last: daysAgo(40), nearPlace: true)],
        now: now, calendar: cal
    )
    #expect(ranked.count == 3)
    for p in ranked {
        #expect(p.headline != nil, "\(p.displayName) surfaced with no reason")
        #expect(!(p.headline ?? "").isEmpty)
    }
}

@Test("Overdue copy hedges — Hearth knows what it noticed, not what happened")
func overdueCopyIsHedged() {
    let scorer = RelationshipScorer()
    let scored = scorer.score(person(last: daysAgo(90)), now: now, calendar: cal)
    let text = scored.reasons.first { $0.kind == .overdue }?.text ?? ""
    // iOS exposes no call/message history. Claiming "you haven't spoken" would be false
    // for anyone who phones daily, and would destroy trust in the whole surface.
    #expect(text.contains("noted"), "copy was: \(text)")
    #expect(!text.lowercased().contains("spoken"))
    #expect(!text.lowercased().contains("talked"))
}

@Test("An imminent birthday outranks a merely overdue contact")
func birthdayBeatsOverdue() {
    let scorer = RelationshipScorer()
    var c = DateComponents(); c.year = 1985; c.month = 6; c.day = 16
    let ranked = scorer.rank(
        [person(name: "Overdue", tier: .close, last: daysAgo(200)),
         person(name: "Birthday", tier: .close, last: daysAgo(20), birthday: cal.date(from: c)!)],
        now: now, calendar: cal
    )
    #expect(ranked.first?.displayName == "Birthday")
}

@Test("A sooner event outranks a later one")
func soonerEventRanksHigher() {
    let scorer = RelationshipScorer()
    let ranked = scorer.rank(
        [person(name: "Later", last: daysAgo(30), event: daysAhead(6), eventTitle: "Dinner"),
         person(name: "Sooner", last: daysAgo(30), event: daysAhead(1), eventTitle: "Lunch")],
        now: now, calendar: cal
    )
    #expect(ranked.first?.displayName == "Sooner")
}

@Test("Events beyond a week don't surface")
func distantEventsIgnored() {
    let scorer = RelationshipScorer()
    let scored = scorer.score(
        person(last: daysAgo(1), event: daysAhead(30), eventTitle: "Wedding"), now: now, calendar: cal
    )
    #expect(!scored.reasons.contains { $0.kind == .upcomingEvent })
}

@Test("Scores are never negative")
func scoresNeverNegative() {
    let scorer = RelationshipScorer()
    let scored = scorer.score(
        person(last: now.addingTimeInterval(-600), unactioned: 20), now: now, calendar: cal
    )
    #expect(scored.score >= 0)
}

// MARK: - Headline selection

@Test("A nearby-place reason headlines over a larger overdue score")
func nearbyBeatsOverdueInHeadline() {
    let scorer = RelationshipScorer()
    // Overdue contributes more numerically, but "you're near Joe's Coffee" is what the
    // user can act on right now. Picking by magnitude produced cards telling you someone
    // was out of touch while you stood next to them.
    let scored = scorer.score(
        person(name: "Joe", tier: .keptWarm, last: daysAgo(140), nearPlace: true),
        now: now, calendar: cal
    )
    let overdue = scored.reasons.first { $0.kind == .overdue }?.contribution ?? 0
    let nearby = scored.reasons.first { $0.kind == .nearbyPlace }?.contribution ?? 0
    #expect(overdue > nearby, "precondition: overdue should be the larger term")
    #expect(scored.headline?.contains("Joe's Coffee") == true, "headline was: \(scored.headline ?? "nil")")
}

@Test("A birthday headlines over an overdue contact")
func birthdayHeadlinesOverOverdue() {
    let scorer = RelationshipScorer()
    var c = DateComponents(); c.year = 1985; c.month = 6; c.day = 17
    let scored = scorer.score(
        person(name: "Sarah Chen", last: daysAgo(200), birthday: cal.date(from: c)!),
        now: now, calendar: cal
    )
    #expect(scored.headline?.contains("birthday") == true, "headline was: \(scored.headline ?? "nil")")
}

@Test("Negative reasons never become the headline")
func negativeReasonsAreNotHeadlines() {
    let scorer = RelationshipScorer()
    let scored = scorer.score(
        person(tier: .close, last: daysAgo(60), unactioned: 4), now: now, calendar: cal
    )
    #expect(scored.headline?.contains("Shown recently") != true)
    #expect(scored.headline?.contains("in touch recently") != true)
}

@Test("Supporting reasons exclude the headline and all negatives")
func supportingReasonsAreDistinct() {
    let scorer = RelationshipScorer()
    var c = DateComponents(); c.year = 1985; c.month = 6; c.day = 17
    let scored = scorer.score(
        person(name: "Sarah", last: daysAgo(120), birthday: cal.date(from: c)!, nearPlace: true),
        now: now, calendar: cal
    )
    #expect(!scored.supportingReasons.contains { $0.text == scored.headline })
    #expect(scored.supportingReasons.allSatisfy { $0.contribution > 0 })
}
