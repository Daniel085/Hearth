import CoreData
import Contacts
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

    /// Sets a per-person contact interval, or nil to fall back to the tier default.
    func setCadenceTargetDays(_ days: Int?, for person: CDPerson) {
        person.cadenceTargetDays = days.map(NSNumber.init)
        person.updatedAt = Date()
        save()
    }

    func setDisplayName(_ name: String, for person: CDPerson) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        person.displayName = trimmed
        person.updatedAt = Date()
        save()
    }

    func setBirthday(_ date: Date?, for person: CDPerson) {
        person.birthday = date
        person.updatedAt = Date()
        save()
    }

    /// Interactions newest first.
    func interactions(for person: CDPerson) -> [CDInteraction] {
        let set = person.interactions as? Set<CDInteraction> ?? []
        return set.sorted { $0.date > $1.date }
    }

    /// Distinct photos this person appears in, across all their face groups.
    ///
    /// Counts distinct assets rather than faces: twelve faces from one burst is one
    /// photo of evidence, not twelve.
    func photoCount(for person: CDPerson) -> Int {
        let appearances = person.appearances as? Set<CDPhotoAppearance> ?? []
        return Set(appearances.map(\.localIdentifier)).count
    }

    /// Span of photos containing this person, for "known since" context.
    func photoDateRange(for person: CDPerson) -> ClosedRange<Date>? {
        let appearances = person.appearances as? Set<CDPhotoAppearance> ?? []
        let dates = appearances.compactMap(\.captureDate).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return first...last
    }

    /// Photo identifiers for a face group, oldest first, for the thumbnail strip.
    func appearances(in group: CDFaceGroup) -> [CDPhotoAppearance] {
        let set = group.appearances as? Set<CDPhotoAppearance> ?? []
        return set.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
    }

    /// Detaches a face group from its person, without deleting the photo records.
    ///
    /// The correction for a group assigned to the wrong person. It becomes unassigned
    /// rather than destroyed, so the underlying scan data survives.
    func detach(_ group: CDFaceGroup) {
        group.person = nil
        let appearances = group.appearances as? Set<CDPhotoAppearance> ?? []
        for appearance in appearances {
            appearance.person = nil
            appearance.faceGroup = nil
        }
        context.delete(group)
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
    ///
    /// `upcomingEvents` is passed in rather than fetched here: the calendar lives behind
    /// its own permission and its own service, and keeping this method free of EventKit
    /// means it stays testable with plain values.
    func scoringInputs(
        now: Date = Date(),
        upcomingEvents: [UUID: UpcomingEvent] = [:]
    ) -> [ScoringInput] {
        allPeople().map { person in
            let event = upcomingEvents[person.id]
            return ScoringInput(
                personID: person.id,
                displayName: person.displayName ?? "Unknown",
                tier: RelationshipTier(rawValue: person.tier) ?? .close,
                cadenceTargetDays: person.cadenceTargetDays?.intValue,
                lastInteraction: lastInteraction(for: person),
                birthday: person.birthday,
                upcomingEventDate: event?.date,
                upcomingEventTitle: event?.title,
                isNearAssociatedPlace: false, // Core Location not wired yet
                nearbyPlaceName: nil,
                unactionedAppearances: 0,     // needs Signal history
                isMuted: person.isMuted
            )
        }
    }

    /// Matches a set of event attendees to a person, by contact link first, then name.
    ///
    /// Contact identity is more reliable than a display name — two people can share a
    /// first name, and calendar names are often just "Mum" or a raw email local-part.
    /// Falls back to case-insensitive exact name match, which is good enough for the
    /// common case and never wrong in the confident direction (a partial-name match could
    /// attach "Sam Smith"'s dinner to "Sam Jones", so we don't do partials).
    func matchPerson(to attendees: EventAttendees) -> UUID? {
        let people = allPeople()

        // 1. By linked contact email.
        if !attendees.emails.isEmpty {
            let emailSet = Set(attendees.emails.map { $0.lowercased() })
            for person in people {
                guard let identifier = person.contactIdentifier,
                      let contactEmails = contactEmails(for: identifier), !contactEmails.isEmpty
                else { continue }
                if !contactEmails.isDisjoint(with: emailSet) { return person.id }
            }
        }

        // 2. By exact, case-insensitive name.
        let nameSet = Set(attendees.names.map { $0.lowercased() })
        for person in people {
            if let name = person.displayName?.lowercased(), nameSet.contains(name) {
                return person.id
            }
        }

        return nil
    }

    private func contactEmails(for identifier: String) -> Set<String>? {
        let keys = [CNContactEmailAddressesKey as CNKeyDescriptor]
        guard let contact = try? CNContactStore().unifiedContact(
            withIdentifier: identifier, keysToFetch: keys
        ) else { return nil }
        return Set(contact.emailAddresses.map { ($0.value as String).lowercased() })
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
