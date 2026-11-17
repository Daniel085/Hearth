import CoreData
import Foundation
import Testing
@testable import Hearth

@MainActor
private func makeStore() -> PersonStore {
    let container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.shared)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in precondition(error == nil) }
    return PersonStore(context: container.viewContext)
}

private let salt = "test-salt"

private func sparkPerson(
    _ name: String, handles: [String] = [], tier: SparkTier = .close, lastContact: String? = nil
) -> SparkPerson {
    SparkPerson(
        name: name,
        matchKeys: handles.map { MatchKey.hash($0, salt: salt) },
        suggestedTier: tier,
        lastContactMonth: lastContact,
        reasons: ["Messaged both ways this past year (10 sent, 12 received)"]
    )
}

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

// MARK: - Matching

@Test
func matchesPhoneContactsByHashedHandles() {
    let file = SparkFile(createdMonth: "2026-11", salt: salt, people: [
        sparkPerson("Jane Doe", handles: ["4155550100", "jane@example.com"]),
        sparkPerson("Sam Lee", handles: ["6505550199"]),
        sparkPerson("Unknown", handles: ["2125550123"]),
    ])
    let contacts = [
        SparkImport.PhoneContact(identifier: "C-JANE", handles: [Handle.normalize("+1 (415) 555-0100")!]),
        SparkImport.PhoneContact(identifier: "C-SAM", handles: ["sam@example.com", "6505550199"]),
    ]
    #expect(SparkImport.match(file, against: contacts) == [0: "C-JANE", 1: "C-SAM"])
}

@Test
func aDifferentSaltMatchesNothing() {
    // The hashes are tied to the file's salt; a phone using any other salt can't match.
    var file = SparkFile(createdMonth: "2026-11", salt: salt, people: [sparkPerson("Jane", handles: ["4155550100"])])
    file.salt = "another-salt"
    let contacts = [SparkImport.PhoneContact(identifier: "C", handles: ["4155550100"])]
    #expect(SparkImport.match(file, against: contacts).isEmpty)
}

// MARK: - Saving

@Test @MainActor
func importSavesNameTierAndContactLink() throws {
    let store = makeStore()
    let added = store.importSpark([
        (sparkPerson("Jane Doe", tier: .innerCircle), "C-JANE"),
        (sparkPerson("Sam Lee", tier: .keptWarm), nil),
    ], calendar: utc)

    #expect(added == 2)
    let jane = try #require(store.person(named: "Jane Doe"))
    #expect(jane.tier == RelationshipTier.innerCircle.rawValue)
    #expect(jane.contactIdentifier == "C-JANE")
    #expect(store.person(named: "Sam Lee")?.tier == RelationshipTier.keptWarm.rawValue)
}

@Test @MainActor
func peopleAlreadyInHearthKeepTheirCloseness() throws {
    let store = makeStore()
    store.findOrCreatePerson(named: "Jane Doe", tier: .close)
    let added = store.importSpark([(sparkPerson("jane doe", tier: .keptWarm), nil)], calendar: utc)
    #expect(added == 0)
    #expect(store.allPeople().count == 1)
    #expect(store.person(named: "Jane Doe")?.tier == RelationshipTier.close.rawValue)
}

@Test @MainActor
func matchedContactLinksToTheExistingPersonEvenUnderAnotherName() throws {
    let store = makeStore()
    store.findOrCreatePerson(named: "Mum", tier: .innerCircle, contactIdentifier: "C-MUM")
    let added = store.importSpark([(sparkPerson("Margaret Doe", tier: .close), "C-MUM")], calendar: utc)
    #expect(added == 0)
    #expect(store.allPeople().map(\.displayName) == ["Mum"])
}

@Test @MainActor
func lastContactMonthBecomesOneLowConfidenceInteraction() throws {
    let store = makeStore()
    store.importSpark([(sparkPerson("Jane Doe", lastContact: "2026-10"), nil)], calendar: utc)

    let jane = try #require(store.person(named: "Jane Doe"))
    let interactions = store.interactions(for: jane)
    #expect(interactions.count == 1)
    let interaction = try #require(interactions.first)
    #expect(interaction.source == InteractionSource.sparkImport.rawValue)
    #expect(interaction.kind == InteractionKind.summary.rawValue)
    #expect(interaction.confidence == InteractionSource.sparkImport.confidence)
    #expect(interaction.confidence < InteractionSource.launchpadAction.confidence)
    #expect(utc.dateComponents([.year, .month, .day], from: interaction.date)
        == DateComponents(year: 2026, month: 10, day: 15))
}

@Test @MainActor
func aNewerInteractionInHearthIsNotOverwrittenByAnOlderMonth() throws {
    let store = makeStore()
    let jane = try #require(store.findOrCreatePerson(named: "Jane Doe"))
    let recent = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 3)))
    store.recordInteraction(with: jane, kind: .call, source: .userLogged, date: recent)

    store.importSpark([(sparkPerson("Jane Doe", lastContact: "2026-09"), nil)], calendar: utc)
    #expect(store.interactions(for: jane).count == 1)
}

@Test
func monthParsing() {
    #expect(PersonStore.middle(ofMonth: "2026-02", calendar: utc).map { utc.component(.day, from: $0) } == 15)
    #expect(PersonStore.middle(ofMonth: "2026-13", calendar: utc) == nil)
    #expect(PersonStore.middle(ofMonth: "soon", calendar: utc) == nil)
}

@Test
func everySparkTierMapsToTheSameNamedHearthTier() {
    for tier in SparkTier.allCases {
        #expect(String(describing: RelationshipTier(tier)) == tier.rawValue)
    }
}

// MARK: - The received file

@Test
func receivedFileIsReadThenDeleted() throws {
    let file = SparkFile(createdMonth: "2026-11", salt: salt, people: [sparkPerson("Jane")])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).hearthspark")
    try file.encoded().write(to: url)

    #expect(try SparkImport.load(url) == file)
    #expect(SparkImport.delete(url))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test
func aFileFromANewerSparkIsRefused() throws {
    var file = SparkFile(createdMonth: "2026-11", salt: salt, people: [])
    file.version = SparkFile.currentVersion + 1
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).hearthspark")
    try file.encoded().write(to: url)
    defer { SparkImport.delete(url) }
    #expect(throws: SparkError.unsupportedFile) { try SparkImport.load(url) }
}
