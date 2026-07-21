import CoreData
import Foundation

/// The Core Data schema from `docs/data-model.md`, defined in code.
///
/// Built programmatically rather than as an `.xcdatamodeld` bundle so the schema is
/// reviewable in a diff. The editor format is binary-ish XML that reviews poorly and
/// merges worse.
enum HearthModel {

    static let shared: NSManagedObjectModel = {
        let model = NSManagedObjectModel()

        let person = NSEntityDescription()
        person.name = "CDPerson"
        person.managedObjectClassName = "CDPerson"

        let interaction = NSEntityDescription()
        interaction.name = "CDInteraction"
        interaction.managedObjectClassName = "CDInteraction"

        let appearance = NSEntityDescription()
        appearance.name = "CDPhotoAppearance"
        appearance.managedObjectClassName = "CDPhotoAppearance"

        let signal = NSEntityDescription()
        signal.name = "CDSignal"
        signal.managedObjectClassName = "CDSignal"

        person.properties = [
            attr("id", .UUIDAttributeType),
            attr("displayName", .stringAttributeType, optional: true),
            attr("contactIdentifier", .stringAttributeType, optional: true),
            attr("faceClusterID", .UUIDAttributeType, optional: true),
            attr("birthday", .dateAttributeType, optional: true),
            attr("tier", .integer16AttributeType, default: 1),
            attr("cadenceTargetDays", .integer32AttributeType, optional: true),
            attr("isMuted", .booleanAttributeType, default: false),
            attr("createdAt", .dateAttributeType),
            attr("updatedAt", .dateAttributeType),
        ]

        interaction.properties = [
            attr("id", .UUIDAttributeType),
            attr("date", .dateAttributeType),
            attr("kind", .integer16AttributeType, default: 0),
            attr("direction", .integer16AttributeType, default: 0),
            attr("source", .integer16AttributeType, default: 0),
            attr("confidence", .doubleAttributeType, default: 1.0),
        ]

        appearance.properties = [
            attr("id", .UUIDAttributeType),
            // PHAsset.localIdentifier — we store the reference, never the pixels.
            attr("localIdentifier", .stringAttributeType),
            attr("captureDate", .dateAttributeType, optional: true),
            attr("clusterID", .UUIDAttributeType, optional: true),
            attr("detectionConfidence", .floatAttributeType, default: 0.0),
            attr("captureQuality", .floatAttributeType, optional: true),
            attr("relativeSize", .doubleAttributeType, default: 0.0),
            attr("yawDegrees", .doubleAttributeType, default: 0.0),
            attr("rollDegrees", .doubleAttributeType, default: 0.0),
            attr("embedding", .binaryDataAttributeType, optional: true),
            attr("latitude", .doubleAttributeType, optional: true),
            attr("longitude", .doubleAttributeType, optional: true),
        ]

        signal.properties = [
            attr("id", .UUIDAttributeType),
            attr("kind", .integer16AttributeType, default: 0),
            attr("score", .doubleAttributeType, default: 0.0),
            attr("reasonText", .stringAttributeType, default: ""),
            attr("validUntil", .dateAttributeType),
            attr("dismissedAt", .dateAttributeType, optional: true),
        ]

        // Relationships. Each pair must be wired as inverses or Core Data warns and
        // delete propagation misbehaves.
        link(
            from: person, name: "interactions", to: interaction, toMany: true,
            inverseName: "person", deleteRule: .cascadeDeleteRule
        )
        link(
            from: person, name: "appearances", to: appearance, toMany: true,
            inverseName: "person", deleteRule: .nullifyDeleteRule
        )
        link(
            from: person, name: "signals", to: signal, toMany: true,
            inverseName: "person", deleteRule: .cascadeDeleteRule
        )

        model.entities = [person, interaction, appearance, signal]
        return model
    }()

    private static func attr(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        default defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        a.defaultValue = defaultValue
        return a
    }

    /// Creates a relationship and its inverse in one step.
    private static func link(
        from: NSEntityDescription,
        name: String,
        to: NSEntityDescription,
        toMany: Bool,
        inverseName: String,
        deleteRule: NSDeleteRule
    ) {
        let forward = NSRelationshipDescription()
        forward.name = name
        forward.destinationEntity = to
        forward.minCount = 0
        forward.maxCount = toMany ? 0 : 1
        forward.deleteRule = deleteRule

        let inverse = NSRelationshipDescription()
        inverse.name = inverseName
        inverse.destinationEntity = from
        inverse.minCount = 0
        inverse.maxCount = 1
        inverse.isOptional = true
        inverse.deleteRule = .nullifyDeleteRule

        forward.inverseRelationship = inverse
        inverse.inverseRelationship = forward

        from.properties.append(forward)
        to.properties.append(inverse)
    }
}

// MARK: - Managed object subclasses

@objc(CDPerson)
final class CDPerson: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var displayName: String?
    @NSManaged var contactIdentifier: String?
    @NSManaged var faceClusterID: UUID?
    @NSManaged var birthday: Date?
    @NSManaged var tier: Int16
    @NSManaged var cadenceTargetDays: NSNumber?
    @NSManaged var isMuted: Bool
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var interactions: NSSet?
    @NSManaged var appearances: NSSet?
    @NSManaged var signals: NSSet?
}

@objc(CDInteraction)
final class CDInteraction: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var date: Date
    @NSManaged var kind: Int16
    @NSManaged var direction: Int16
    @NSManaged var source: Int16
    @NSManaged var confidence: Double
    @NSManaged var person: CDPerson?
}

@objc(CDPhotoAppearance)
final class CDPhotoAppearance: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var localIdentifier: String
    @NSManaged var captureDate: Date?
    @NSManaged var clusterID: UUID?
    @NSManaged var detectionConfidence: Float
    @NSManaged var captureQuality: NSNumber?
    @NSManaged var relativeSize: Double
    @NSManaged var yawDegrees: Double
    @NSManaged var rollDegrees: Double
    @NSManaged var embedding: Data?
    @NSManaged var latitude: NSNumber?
    @NSManaged var longitude: NSNumber?
    @NSManaged var person: CDPerson?
}

@objc(CDSignal)
final class CDSignal: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var kind: Int16
    @NSManaged var score: Double
    @NSManaged var reasonText: String
    @NSManaged var validUntil: Date
    @NSManaged var dismissedAt: Date?
    @NSManaged var person: CDPerson?
}

// MARK: - Stack

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.shared)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { _, error in
            if let error {
                // Fatal during development so schema mistakes surface immediately rather
                // than silently degrading to an app with no storage.
                fatalError("Core Data failed to load: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
