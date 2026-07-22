import Testing
import Foundation
import CoreData
@testable import Hearth

/// Covers the store operations the detail view drives. The SwiftUI layer can't be
/// exercised headlessly, but these are the parts that can actually corrupt data.
@MainActor
private func makeStore() -> PersonStore {
    let container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.shared)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in precondition(error == nil) }
    return PersonStore(context: container.viewContext)
}

@MainActor
private func face(_ asset: String, day: Double) -> FaceDescriptor {
    FaceDescriptor(
        assetIdentifier: asset,
        captureDate: Date(timeIntervalSince1970: day * 86_400),
        detectionConfidence: 0.9, captureQuality: 0.8, relativeSize: 0.2,
        yawDegrees: 0, rollDegrees: 0, embedding: Embedding(values: [1, 2, 3])
    )
}

@Test @MainActor
func tierChangesPersistAndDriveCadence() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!

    store.setTier(.innerCircle, for: person)
    #expect(store.scoringInputs()[0].tier == .innerCircle)
    // With no override, cadence follows the tier.
    #expect(store.scoringInputs()[0].cadenceDays == 7)

    store.setTier(.distant, for: person)
    #expect(store.scoringInputs()[0].cadenceDays == 365)
}

@Test @MainActor
func customCadenceOverridesTierAndClearsBackToNil() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam", tier: .distant)!

    store.setCadenceTargetDays(14, for: person)
    #expect(store.scoringInputs()[0].cadenceDays == 14)

    // Turning the toggle off must fall back to the tier default, not to zero —
    // a zero cadence would make overdueRatio undefined.
    store.setCadenceTargetDays(nil, for: person)
    #expect(store.scoringInputs()[0].cadenceTargetDays == nil)
    #expect(store.scoringInputs()[0].cadenceDays == 365)
}

@Test @MainActor
func renamingKeepsTheSamePersonAndTheirData() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sara")!
    store.attachFaceGroups([FaceGroupSnapshot(cluster: FaceCluster(faces: [face("a", day: 10)]))], to: person)

    store.setDisplayName("Sarah Chen", for: person)

    #expect(store.allPeople().count == 1)
    #expect(store.person(named: "Sarah Chen") != nil)
    #expect(store.faceGroups(for: person).count == 1)
}

@Test @MainActor
func renamingToBlankIsIgnored() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!
    store.setDisplayName("   ", for: person)
    #expect(person.displayName == "Sam")
}

@Test @MainActor
func photoCountUsesDistinctAssetsNotFaces() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!
    // Three faces, two photos — a burst shouldn't inflate the count.
    let cluster = FaceCluster(faces: [
        face("shot1", day: 10), face("shot1", day: 10), face("shot2", day: 11),
    ])
    store.attachFaceGroups([FaceGroupSnapshot(cluster: cluster)], to: person)
    #expect(store.photoCount(for: person) == 2)
}

@Test @MainActor
func photoDateRangeSpansAllGroups() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Baby")!
    store.attachFaceGroups([
        FaceGroupSnapshot(cluster: FaceCluster(faces: [face("a", day: 100)])),
        FaceGroupSnapshot(cluster: FaceCluster(faces: [face("b", day: 500)])),
    ], to: person)

    let range = store.photoDateRange(for: person)
    #expect(range != nil)
    #expect(range!.lowerBound == Date(timeIntervalSince1970: 100 * 86_400))
    #expect(range!.upperBound == Date(timeIntervalSince1970: 500 * 86_400))
}

@Test @MainActor
func detachingAGroupLeavesThePersonIntact() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!
    store.attachFaceGroups([
        FaceGroupSnapshot(cluster: FaceCluster(faces: [face("a", day: 10)])),
        FaceGroupSnapshot(cluster: FaceCluster(faces: [face("b", day: 20)])),
    ], to: person)
    #expect(store.faceGroups(for: person).count == 2)

    // "Not them" removes one group without destroying the person.
    let group = store.faceGroups(for: person)[0]
    store.detach(group)

    #expect(store.allPeople().count == 1)
    #expect(store.faceGroups(for: person).count == 1)
}

@Test @MainActor
func interactionHistoryIsNewestFirst() {
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!
    let old = Date(timeIntervalSince1970: 1_000_000)
    let recent = Date(timeIntervalSince1970: 2_000_000)
    store.recordInteraction(with: person, kind: .call, source: .userLogged, date: old)
    store.recordInteraction(with: person, kind: .message, source: .userLogged, date: recent)

    let history = store.interactions(for: person)
    #expect(history.first?.date == recent)
    #expect(history.last?.date == old)
}

@Test @MainActor
func unmutingRestoresSomeoneToTheLaunchpad() {
    // Muting must not be a one-way door — the People list is the route back.
    let store = makeStore()
    let person = store.findOrCreatePerson(named: "Sam")!
    store.recordInteraction(with: person, kind: .call, source: .userLogged,
                            date: Date(timeIntervalSince1970: 1_000_000))

    store.setMuted(true, for: person)
    #expect(RelationshipScorer().rank(store.scoringInputs(), now: Date()).isEmpty)

    store.setMuted(false, for: person)
    #expect(!RelationshipScorer().rank(store.scoringInputs(), now: Date()).isEmpty)
}
