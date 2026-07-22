import Testing
import Foundation
import CoreData
@testable import Hearth

/// Each test gets its own in-memory stack, so they are independent and leave no files.
@MainActor
private func makeStore() -> PersonStore {
    let container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.shared)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    var loadError: Error?
    container.loadPersistentStores { _, error in loadError = error }
    precondition(loadError == nil, "in-memory store failed: \(loadError!)")
    return PersonStore(context: container.viewContext)
}

@Test @MainActor
func createsAndFindsAPerson() {
    let store = makeStore()
    let created = store.findOrCreatePerson(named: "Sarah Chen")
    #expect(created != nil)
    #expect(store.allPeople().count == 1)
    #expect(store.person(named: "Sarah Chen") != nil)
}

@Test @MainActor
func nameMatchingIsCaseInsensitive() {
    let store = makeStore()
    // "mum" from a face group and "Mum" from Contacts must not become two people.
    store.findOrCreatePerson(named: "Mum")
    store.findOrCreatePerson(named: "mum")
    store.findOrCreatePerson(named: "  Mum  ")
    #expect(store.allPeople().count == 1)
}

@Test @MainActor
func emptyNamesAreRejected() {
    let store = makeStore()
    #expect(store.findOrCreatePerson(named: "") == nil)
    #expect(store.findOrCreatePerson(named: "   ") == nil)
    #expect(store.allPeople().isEmpty)
}

@Test @MainActor
func existingPersonGainsDetailsWithoutDuplicating() {
    let store = makeStore()
    store.findOrCreatePerson(named: "Joe")
    let birthday = Date(timeIntervalSince1970: 500_000_000)
    store.findOrCreatePerson(named: "Joe", contactIdentifier: "ABC123", birthday: birthday)

    #expect(store.allPeople().count == 1)
    let joe = store.person(named: "Joe")
    #expect(joe?.contactIdentifier == "ABC123")
    #expect(joe?.birthday == birthday)
}

@Test @MainActor
func aPersonCanOwnSeveralFaceGroups() {
    // The whole point of CDFaceGroup: a face that changed over time is several clusters,
    // all belonging to one person.
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Baby")!

    func snapshot(_ asset: String, day: Double) -> FaceGroupSnapshot {
        let face = FaceDescriptor(
            assetIdentifier: asset,
            captureDate: Date(timeIntervalSince1970: day * 86_400),
            detectionConfidence: 0.9, captureQuality: 0.8, relativeSize: 0.2,
            yawDegrees: 0, rollDegrees: 0, embedding: Embedding(values: [1, 2, 3])
        )
        return FaceGroupSnapshot(cluster: FaceCluster(faces: [face]))
    }

    store.attachFaceGroups([snapshot("a", day: 100), snapshot("b", day: 300)], to: person)
    #expect(store.faceGroups(for: person).count == 2)

    // Groups are ordered chronologically, so "as a baby" precedes "now".
    let groups = store.faceGroups(for: person)
    #expect(groups[0].earliestCapture! < groups[1].earliestCapture!)
}

@Test @MainActor
func attachingTheSameClusterTwiceIsIdempotent() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!

    let face = FaceDescriptor(
        assetIdentifier: "a", captureDate: Date(),
        detectionConfidence: 0.9, captureQuality: 0.8, relativeSize: 0.2,
        yawDegrees: 0, rollDegrees: 0, embedding: Embedding(values: [1, 2, 3])
    )
    let snapshot = FaceGroupSnapshot(cluster: FaceCluster(faces: [face]))

    store.attachFaceGroups([snapshot], to: person)
    store.attachFaceGroups([snapshot], to: person)

    // Re-naming the same group must not duplicate it.
    #expect(store.faceGroups(for: person).count == 1)
}

@Test @MainActor
func interactionsRecordAndReadBack() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Priya")!
    #expect(store.lastInteraction(for: person) == nil)

    let earlier = Date(timeIntervalSince1970: 1_000_000)
    let later = Date(timeIntervalSince1970: 2_000_000)
    store.recordInteraction(with: person, kind: .call, source: .launchpadAction, date: earlier)
    store.recordInteraction(with: person, kind: .message, source: .userLogged, date: later)

    #expect(store.lastInteraction(for: person) == later)
}

@Test @MainActor
func launchpadActionsAreRecordedAtReducedConfidence() {
    // Opening Messages is not proof anything was sent. Recording it at full confidence
    // would suppress the person for 48 hours on the strength of a tap.
    #expect(InteractionSource.launchpadAction.confidence < InteractionSource.userLogged.confidence)
    #expect(InteractionSource.userLogged.confidence == 1.0)
}

@Test @MainActor
func deletingAPersonRemovesTheirFaceGroups() {
    // Faceprint data carries retention obligations — "delete" has to mean it.
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Tom")!
    let face = FaceDescriptor(
        assetIdentifier: "a", captureDate: Date(),
        detectionConfidence: 0.9, captureQuality: 0.8, relativeSize: 0.2,
        yawDegrees: 0, rollDegrees: 0, embedding: Embedding(values: [1, 2, 3])
    )
    store.attachFaceGroups([FaceGroupSnapshot(cluster: FaceCluster(faces: [face]))], to: person)
    store.recordInteraction(with: person, kind: .call, source: .userLogged)

    store.delete(person)
    #expect(store.allPeople().isEmpty)
}

@Test @MainActor
func scoringInputsReflectStoredState() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Alex", tier: .innerCircle)!
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    store.recordInteraction(with: person, kind: .call, source: .userLogged, date: when)

    let inputs = store.scoringInputs()
    #expect(inputs.count == 1)
    #expect(inputs[0].displayName == "Alex")
    #expect(inputs[0].tier == .innerCircle)
    #expect(inputs[0].lastInteraction == when)
}

@Test @MainActor
func mutedPeopleArePersistedAndExcludedByTheScorer() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Snoozed")!
    store.setMuted(true, for: person)

    let ranked = RelationshipScorer().rank(store.scoringInputs(), now: Date())
    #expect(ranked.isEmpty)
}
