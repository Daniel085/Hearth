import Testing
import Foundation
import CoreData
@testable import Hearth

/// Shaped like a real export: the free-text preamble, quoted fields with commas, a
/// restricted member with no name, and a duplicate row.
private let sampleExport = #"""
Notes:
"When exporting your connection data, you may notice that some of the email addresses are missing. You will only see email addresses for connections who have allowed their connections to see or download their email address using this setting https://www.linkedin.com/psettings/privacy/email. You can learn more about this here: https://www.linkedin.com/help/linkedin/answer/261"

First Name,Last Name,URL,Email Address,Company,Position,Connected On
Sarah,Chen,https://www.linkedin.com/in/sarahchen,,"Acme, Inc.",Product Designer,14 Nov 2026
Joe,Bloggs,https://www.linkedin.com/in/joebloggs,joe@example.com,,,03 Feb 2019
,,,,,,01 Jan 2020
Sarah,Chen,https://www.linkedin.com/in/sarahchen,,"Acme, Inc.",Product Designer,14 Nov 2026
"Ann ""AJ""",O'Neil,https://www.linkedin.com/in/aj,,Studio,"Lead,
Research",5 Mar 2021
"""#

@Test
func parsesPastThePreambleAndHandlesQuoting() throws {
    let connections = try LinkedInConnectionsParser.parse(sampleExport)

    // Restricted member dropped, duplicate folded.
    #expect(connections.map(\.fullName) == ["Sarah Chen", "Joe Bloggs", "Ann \"AJ\" O'Neil"])

    let sarah = connections[0]
    #expect(sarah.company == "Acme, Inc.")
    #expect(sarah.position == "Product Designer")
    #expect(sarah.email == nil)
    #expect(sarah.workSummary == "Product Designer at Acme, Inc.")
    #expect(sarah.profileURL?.absoluteString == "https://www.linkedin.com/in/sarahchen")

    let joe = connections[1]
    #expect(joe.email == "joe@example.com")
    #expect(joe.workSummary == nil)

    // A newline inside a quoted field stays in the field rather than splitting the row.
    #expect(connections[2].position == "Lead,\nResearch")
}

@Test
func parsesConnectedOnDates() throws {
    let connections = try LinkedInConnectionsParser.parse(sampleExport)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = try #require(connections[1].connectedOn)
    #expect(calendar.dateComponents([.year, .month, .day], from: date)
        == DateComponents(year: 2019, month: 2, day: 3))
    // Single-digit day.
    #expect(connections[2].connectedOn != nil)
}

@Test
func mapsColumnsByNameNotPosition() throws {
    let reordered = """
    \u{FEFF}Company,Last Name,First Name\r
    Acme,Chen,Sarah\r
    """
    let connections = try LinkedInConnectionsParser.parse(reordered)
    #expect(connections.count == 1)
    #expect(connections[0].fullName == "Sarah Chen")
    #expect(connections[0].company == "Acme")
}

@Test
func rejectsFilesThatAreNotConnectionsExports() {
    #expect(throws: LinkedInImportError.notAConnectionsFile) {
        try LinkedInConnectionsParser.parse("Name,Phone\nSarah,555\n")
    }
}

// MARK: - Store

@MainActor
private func makeStore() -> PersonStore {
    let container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.shared)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in precondition(error == nil) }
    return PersonStore(context: container.viewContext)
}

@Test @MainActor
func importAddsPeopleWithWorkDetails() throws {
    let store = makeStore()
    let connections = try LinkedInConnectionsParser.parse(sampleExport)

    let added = store.importLinkedInConnections(Array(connections.prefix(1)), tier: .keptWarm)

    #expect(added == 1)
    let sarah = try #require(store.person(named: "Sarah Chen"))
    #expect(sarah.tier == RelationshipTier.keptWarm.rawValue)
    #expect(sarah.organization == "Acme, Inc.")
    #expect(sarah.jobTitle == "Product Designer")
    #expect(sarah.linkedInURL == "https://www.linkedin.com/in/sarahchen")
    #expect(sarah.connectedOn != nil)
}

@Test @MainActor
func importEnrichesExistingPeopleWithoutOverwriting() throws {
    let store = makeStore()
    // Already added from Contacts as inner circle, with a title the user typed.
    let existing = try #require(store.findOrCreatePerson(named: "sarah chen", tier: .innerCircle))
    existing.jobTitle = "Head of Design"

    let connections = try LinkedInConnectionsParser.parse(sampleExport)
    let added = store.importLinkedInConnections(Array(connections.prefix(1)), tier: .distant)

    #expect(added == 0)
    #expect(store.allPeople().count == 1)
    #expect(existing.tier == RelationshipTier.innerCircle.rawValue)
    #expect(existing.jobTitle == "Head of Design")
    #expect(existing.organization == "Acme, Inc.")
}

// MARK: - Migration

@Test @MainActor
func versionOneStoreMigratesAndKeepsItsPeople() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("Hearth.sqlite")

    // Write a store with the v1 schema, as an existing install would have.
    let v1 = HearthModel.history[0]
    let old = NSPersistentStoreCoordinator(managedObjectModel: v1)
    let oldStore = try old.addPersistentStore(type: .sqlite, at: url)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = old
    let person = NSManagedObject(entity: v1.entitiesByName["CDPerson"]!, insertInto: context)
    person.setValue(UUID(), forKey: "id")
    person.setValue("Mum", forKey: "displayName")
    person.setValue(Date(), forKey: "createdAt")
    person.setValue(Date(), forKey: "updatedAt")
    try context.save()
    try old.remove(oldStore)

    try PersistenceController.migrateIfNeeded(storeAt: url)

    let new = NSPersistentStoreCoordinator(managedObjectModel: HearthModel.shared)
    _ = try new.addPersistentStore(type: .sqlite, at: url)
    let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    newContext.persistentStoreCoordinator = new
    let store = PersonStore(context: newContext)
    let mum = try #require(store.person(named: "Mum"))
    #expect(mum.organization == nil)
}

// MARK: - Signals

@Test
func companyMatchingUsesLeadingWordsNotSubstrings() {
    #expect(LinkedInSignals.sameCompany("Northwind", "NORTHWIND Traders, Inc."))
    #expect(LinkedInSignals.sameCompany("Tailspin Labs", "Tailspin!"))
    #expect(LinkedInSignals.sameCompany("Contoso, Inc.", "Contoso"))
    #expect(LinkedInSignals.sameCompany("Litware/Fabrikam/Adatum", "Fabrikam"))
    // The false match the first prototype made on real data.
    #expect(!LinkedInSignals.sameCompany("Springfield", "UC Springfield"))
    #expect(!LinkedInSignals.sameCompany("Google", "Goodwill"))
}

@Test
func profileSlugsIgnoreURLNoise() {
    #expect(LinkedInSignals.profileSlug("https://www.linkedin.com/in/Jane-Doe/") == "jane-doe")
    #expect(LinkedInSignals.profileSlug("http://linkedin.com/in/jane-doe?trk=x") == "jane-doe")
    #expect(LinkedInSignals.profileSlug("https://example.com/jane") == nil)
}

private func connection(
    _ first: String, _ last: String, slug: String,
    company: String? = nil, connected: String? = nil
) -> LinkedInConnection {
    LinkedInConnection(
        firstName: first, lastName: last, email: nil, company: company, position: nil,
        profileURL: URL(string: "https://www.linkedin.com/in/\(slug)"),
        connectedOn: connected.flatMap(LinkedInConnectionsParser.parseDate)
    )
}

private let signals = LinkedInSignals.parse(
    endorsementsReceived: """
    Endorsement Date,Skill Name,Endorser First Name,Endorser Last Name,Endorser Public Url,Endorsement Status
    2018/07/25 00:27:19,Product,Rosa,Lind,https://www.linkedin.com/in/rosa-lind,ACCEPTED
    2018/07/26 00:27:19,Strategy,Rosa,Lind,www.linkedin.com/in/rosa-lind/,ACCEPTED
    """,
    recommendationsReceived: """
    First Name,Last Name,Company,Job Title,Text,Creation Date,Status
    Omar,Haddad,Acme,CTO,"Great to work with, truly.","02/03/25, 03:30 AM",VISIBLE
    """,
    invitations: """
    From,To,Sent At,Message,Direction,inviterProfileUrl,inviteeProfileUrl
    Me,Kim,"9/22/26, 8:01 PM",Great meeting you at the offsite,OUTGOING,https://www.linkedin.com/in/me,https://www.linkedin.com/in/kim
    Sam,Me,"9/22/26, 8:01 PM",,INCOMING,https://www.linkedin.com/in/sam,https://www.linkedin.com/in/me
    """,
    positions: """
    Company Name,Title,Description,Location,Started On,Finished On
    Fabrikam,Senior PM,,,May 2024,Jan 2025
    Fabrikam,PM,,,Apr 2020,May 2024
    Contoso,Director,,,Jan 2026,
    """
)

@Test
func readsEachSignalFile() {
    #expect(signals.endorsedYou["rosa-lind"] == 2)
    #expect(signals.recommendedYou == ["omar haddad"])
    // Only invitations with a written note count.
    #expect(signals.personalInvites == ["kim"])
    #expect(signals.positions.count == 3)
    #expect(signals.positions[2].end == nil)
}

@Test
func colleaguesNeedToHaveConnectedDuringYourTenure() throws {
    let now = try #require(LinkedInConnectionsParser.parseDate("15 Nov 2026"))
    // Falls in the earlier of two Fabrikam stints — the regression real data caught,
    // where only the first-listed stint was checked.
    let during = signals.suggestion(
        for: connection("A", "B", slug: "ab", company: "Fabrikam", connected: "10 Jun 2021"), now: now)
    #expect(during?.reasons == ["Colleague at Fabrikam"])

    let after = signals.suggestion(
        for: connection("C", "D", slug: "cd", company: "Fabrikam", connected: "10 Jun 2026"), now: now)
    #expect(after?.reasons == ["Works at Fabrikam"])

    // A current job has no end date; tenure runs to now.
    let current = signals.suggestion(
        for: connection("E", "F", slug: "ef", company: "Contoso, Inc.", connected: "1 Mar 2026"), now: now)
    #expect(current?.reasons == ["Colleague at Contoso"])
}

@Test
func recommendationsOutrankEndorsementsAndStrangersGetNothing() {
    let omar = signals.suggestion(for: connection("Omar", "Haddad", slug: "omar"))
    let rosa = signals.suggestion(for: connection("Rosa", "Lind", slug: "rosa-lind"))
    #expect(omar?.reasons == ["Recommended you"])
    #expect(rosa?.reasons == ["Endorsed you 2×"])
    #expect((omar?.score ?? 0) > (rosa?.score ?? 0))
    #expect(signals.suggestion(for: connection("No", "One", slug: "nobody")) == nil)
}
