import CoreData
import Foundation

/// Reads and writes `Person` records.
///
/// The single place Core Data is touched, so the rest of the app works in plain values.
/// Everything is synchronous on the view context: these are tens of records, not
/// thousands, and a background context would add concurrency risk for no measurable gain.
@MainActor
final class PersonStore: ObservableObject {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }

    // MARK: - Reading

    func allPeople() -> [CDPerson] {
        let request = NSFetchRequest<CDPerson>(entityName: "CDPerson")
        request.sortDescriptors = [NSSortDescriptor(key: "displayName", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func person(named name: String) -> CDPerson? {
        let request = NSFetchRequest<CDPerson>(entityName: "CDPerson")
        request.predicate = NSPredicate(format: "displayName ==[c] %@", name)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    func person(withContactIdentifier identifier: String) -> CDPerson? {
        let request = NSFetchRequest<CDPerson>(entityName: "CDPerson")
        request.predicate = NSPredicate(format: "contactIdentifier == %@", identifier)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - Writing

    /// Finds an existing person by name, or creates one.
    ///
    /// Matching is case-insensitive so "mum" and "Mum" don't become two people — a real
    /// hazard when the same person is added once from a face group and once from
    /// Contacts.
    @discardableResult
    func findOrCreatePerson(
        named name: String,
        tier: RelationshipTier = .close,
        contactIdentifier: String? = nil,
        birthday: Date? = nil
    ) -> CDPerson? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let existing = person(named: trimmed) {
            // Fill in anything we now know but didn't before.
            if existing.contactIdentifier == nil, let contactIdentifier {
                existing.contactIdentifier = contactIdentifier
            }
            if existing.birthday == nil, let birthday {
                existing.birthday = birthday
            }
            existing.updatedAt = Date()
            save()
            return existing
        }

        let person = CDPerson(context: context)
        person.id = UUID()
        person.displayName = trimmed
        person.tier = tier.rawValue
        person.contactIdentifier = contactIdentifier
        person.birthday = birthday
        person.isMuted = false
        person.createdAt = Date()
        person.updatedAt = Date()
        save()
        return person
    }

    /// Attaches face groups to a person, one `CDFaceGroup` per cluster.
    ///
    /// Several groups per person is the expected case, not a conflict — a face that
    /// changes over time cannot be gathered into one cluster at a safe threshold.
    /// See `docs/vision-findings.md` §4e.
    func attachFaceGroups(_ groups: [FaceGroupSnapshot], to person: CDPerson) {
        let existing = faceGroups(for: person)
        let existingClusterIDs = Set(existing.map(\.clusterID))

        for snapshot in groups where !existingClusterIDs.contains(snapshot.clusterID) {
            let group = CDFaceGroup(context: context)
            group.id = UUID()
            group.clusterID = snapshot.clusterID
            group.createdAt = Date()
            group.earliestCapture = snapshot.earliestCapture
            group.latestCapture = snapshot.latestCapture
            group.person = person

            for appearance in snapshot.appearances {
                let record = CDPhotoAppearance(context: context)
                record.id = UUID()
                record.localIdentifier = appearance.assetIdentifier
                record.captureDate = appearance.captureDate
                record.clusterID = snapshot.clusterID
                record.detectionConfidence = appearance.detectionConfidence
                record.captureQuality = appearance.captureQuality.map(NSNumber.init)
                record.relativeSize = appearance.relativeSize
                record.yawDegrees = appearance.yawDegrees
                record.rollDegrees = appearance.rollDegrees
                record.person = person
                record.faceGroup = group
            }
        }

        person.updatedAt = Date()
        save()
    }

    func faceGroups(for person: CDPerson) -> [CDFaceGroup] {
        let set = person.faceGroups as? Set<CDFaceGroup> ?? []
        return set.sorted {
            ($0.earliestCapture ?? .distantPast) < ($1.earliestCapture ?? .distantPast)
        }
    }

    /// Records an observed or user-initiated contact.
    ///
    /// `source` matters: a Hearth-launched call means we know the user *tried* to reach
    /// someone, not that they connected. Confidence is set accordingly so the Launchpad
    /// can hedge its copy honestly.
    func recordInteraction(
        with person: CDPerson,
        kind: InteractionKind,
        source: InteractionSource,
        date: Date = Date()
    ) {
        let interaction = CDInteraction(context: context)
        interaction.id = UUID()
        interaction.date = date
        interaction.kind = kind.rawValue
        interaction.direction = 0   // outbound
        interaction.source = source.rawValue
        interaction.confidence = source.confidence
        interaction.person = person

        person.updatedAt = Date()
        save()
    }

    func lastInteraction(for person: CDPerson) -> Date? {
        let set = person.interactions as? Set<CDInteraction> ?? []
        return set.map(\.date).max()
    }

    func setMuted(_ muted: Bool, for person: CDPerson) {
        person.isMuted = muted
        person.updatedAt = Date()
        save()
    }

    func setTier(_ tier: RelationshipTier, for person: CDPerson) {
        person.tier = tier.rawValue
        person.updatedAt = Date()
        save()
    }

    /// Deletes a person and everything derived from them.
    ///
    /// Face groups and interactions cascade. This has to be a real delete, not a hidden
    /// flag: faceprint data carries retention obligations, and "delete" must mean it.
    /// See `docs/core-ml-comparison.md` §3.
    func delete(_ person: CDPerson) {
        context.delete(person)
        save()
    }

    // MARK: - Scoring bridge

    /// Snapshots every person into the plain values the scorer expects.
    func scoringInputs(now: Date = Date()) -> [ScoringInput] {
        allPeople().map { person in
            ScoringInput(
                personID: person.id,
                displayName: person.displayName ?? "Unknown",
                tier: RelationshipTier(rawValue: person.tier) ?? .close,
                cadenceTargetDays: person.cadenceTargetDays?.intValue,
                lastInteraction: lastInteraction(for: person),
                birthday: person.birthday,
                upcomingEventDate: nil,      // EventKit not wired yet
                upcomingEventTitle: nil,
                isNearAssociatedPlace: false, // Core Location not wired yet
                nearbyPlaceName: nil,
                unactionedAppearances: 0,     // needs Signal history
                isMuted: person.isMuted
            )
        }
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            // Rolling back keeps the context usable rather than leaving it wedged with
            // changes that will fail on every subsequent save.
            context.rollback()
            assertionFailure("Core Data save failed: \(error)")
        }
    }
}

// MARK: - Supporting types

/// A cluster ready to be persisted, free of Vision and PhotoKit types.
struct FaceGroupSnapshot: Sendable {
    let clusterID: UUID
    let appearances: [FaceDescriptor]

    var earliestCapture: Date? { appearances.compactMap(\.captureDate).min() }
    var latestCapture: Date? { appearances.compactMap(\.captureDate).max() }

    init(cluster: FaceCluster) {
        self.clusterID = cluster.id
        self.appearances = cluster.faces
    }
}

enum InteractionKind: Int16, Sendable {
    case call = 0
    case message = 1
    case email = 2
    case inPerson = 3
    case calendarEvent = 4
    case manual = 5
}

enum InteractionSource: Int16, Sendable {
    case userLogged = 0
    case calendar = 1
    case photoInference = 2
    case launchpadAction = 3

    /// How much this source is trusted.
    ///
    /// A Launchpad action means we opened Messages — not that anything was sent, or that
    /// the other person replied. iOS gives no way to confirm. Recording it at full
    /// confidence would suppress someone for 48 hours on the strength of a tap.
    var confidence: Double {
        switch self {
        case .userLogged: 1.0
        case .calendar: 0.9
        case .launchpadAction: 0.6
        case .photoInference: 0.5
        }
    }
}
