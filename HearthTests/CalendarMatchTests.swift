import Testing
import Foundation
import CoreData
@testable import Hearth

@MainActor
private func makeStore() -> PersonStore {
    let container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.shared)
    let d = NSPersistentStoreDescription(); d.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [d]
    container.loadPersistentStores { _, e in precondition(e == nil) }
    return PersonStore(context: container.viewContext)
}

@Test @MainActor
func matchesAttendeeByExactName() {
    let store = makeStore()
    let sarah = store.findOrCreatePerson(named: "Sarah Chen")!
    store.findOrCreatePerson(named: "Joe Ramirez")

    let attendees = EventAttendees(names: ["Sarah Chen", "Someone Else"], emails: [])
    #expect(store.matchPerson(to: attendees) == sarah.id)
}

@Test @MainActor
func nameMatchIsCaseInsensitive() {
    let store = makeStore()
    let mum = store.findOrCreatePerson(named: "Mum")!
    let attendees = EventAttendees(names: ["MUM"], emails: [])
    #expect(store.matchPerson(to: attendees) == mum.id)
}

@Test @MainActor
func doesNotMatchOnPartialName() {
    // "Sam" attending must NOT attach to "Sam Jones" — a partial match could put the
    // wrong person's dinner on someone's card. Better to miss than mis-attribute.
    let store = makeStore()
    store.findOrCreatePerson(named: "Sam Jones")
    let attendees = EventAttendees(names: ["Sam"], emails: [])
    #expect(store.matchPerson(to: attendees) == nil)
}

@Test @MainActor
func returnsNilWhenNobodyMatches() {
    let store = makeStore()
    store.findOrCreatePerson(named: "Sarah")
    let attendees = EventAttendees(names: ["Nobody Here"], emails: ["stranger@example.com"])
    #expect(store.matchPerson(to: attendees) == nil)
}

@Test @MainActor
func scoringInputsFoldInUpcomingEvents() {
    let store = makeStore()
    let sarah = store.findOrCreatePerson(named: "Sarah")!
    let when = Date(timeIntervalSince1970: 1_800_000_000)
    let events: [UUID: UpcomingEvent] = [sarah.id: UpcomingEvent(date: when, title: "Dinner")]

    let inputs = store.scoringInputs(upcomingEvents: events)
    let sarahInput = inputs.first { $0.personID == sarah.id }
    #expect(sarahInput?.upcomingEventDate == when)
    #expect(sarahInput?.upcomingEventTitle == "Dinner")
}

@Test @MainActor
func peopleWithoutAnEventGetNilEventFields() {
    let store = makeStore()
    let joe = store.findOrCreatePerson(named: "Joe")!
    let inputs = store.scoringInputs(upcomingEvents: [:])
    #expect(inputs.first { $0.personID == joe.id }?.upcomingEventDate == nil)
}

@Test @MainActor
func aCalendarEventLiftsAPersonAboveAMerelyOverdueOne() {
    // The point of the whole feature: a concrete upcoming event beats a vague "overdue".
    let store = makeStore()
    let overdue = store.findOrCreatePerson(named: "Overdue", tier: .close)!
    let hasEvent = store.findOrCreatePerson(named: "HasEvent", tier: .close)!

    let now = Date(timeIntervalSince1970: 1_750_000_000)
    store.recordInteraction(with: overdue, kind: .call, source: .userLogged,
                            date: now.addingTimeInterval(-200 * 86_400))
    store.recordInteraction(with: hasEvent, kind: .call, source: .userLogged,
                            date: now.addingTimeInterval(-40 * 86_400))

    let events = [hasEvent.id: UpcomingEvent(date: now.addingTimeInterval(2 * 86_400), title: "Lunch")]
    let ranked = RelationshipScorer().rank(store.scoringInputs(upcomingEvents: events), now: now)
    #expect(ranked.first?.displayName == "HasEvent")
    #expect(ranked.first?.headline?.contains("Lunch") == true)
}
