import Contacts
import Foundation

/// What Hearth Spark reads from one contact card.
///
/// Mostly yes/no facts. The birthday and address *values* are never read — whether
/// they're filled in is the signal (people only bother for those who matter), and the
/// iOS app can read the values itself from Contacts if the user links the person.
public struct ContactCard: Equatable, Sendable {
    public var name: String
    public var handles: [String]          // normalized phone numbers and emails
    public var hasBirthday: Bool
    public var hasAddress: Bool
    public var hasNickname: Bool
    /// How the user's own card labels this person — "mother", "partner" — if at all.
    public var relation: String?

    public init(name: String, handles: [String], hasBirthday: Bool = false, hasAddress: Bool = false, hasNickname: Bool = false, relation: String? = nil) {
        self.name = name
        self.handles = handles
        self.hasBirthday = hasBirthday
        self.hasAddress = hasAddress
        self.hasNickname = hasNickname
        self.relation = relation
    }
}

public enum ContactsSource {

    public enum AccessError: LocalizedError {
        /// Never decided, and the request came back refused without a prompt — what
        /// happens when the process running the tool can't show one (an editor's or
        /// app's built-in shell, for instance).
        case promptUnavailable
        /// The user, or an earlier run, said no.
        case denied

        public var errorDescription: String? {
            switch self {
            case .promptUnavailable:
                """
                Hearth Spark needs Contacts access, but macOS couldn't ask for it from here.
                Run it in Terminal (or iTerm) instead — macOS asks there on the first run.
                Contacts can't be added to the permission list by hand, so the prompt is the only way in.
                """
            case .denied:
                """
                Contacts access was turned down for this terminal.
                Switch it on in System Settings → Privacy & Security → Contacts, or reset the
                decision so macOS asks again:  tccutil reset AddressBook com.apple.Terminal
                """
            }
        }
    }

    public static func read() throws -> [ContactCard] {
        let store = CNContactStore()
        try requestAccess(store)

        // Only these keys are fetched. Notes, images, job details, social profiles and
        // the birthday/address values themselves are never requested.
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
        ]

        // Relations are recorded on the user's own "me" card: "Mum — mother".
        var relations: [String: String] = [:]
        let me = try? store.unifiedMeContactWithKeys(toFetch: [CNContactRelationsKey as CNKeyDescriptor])
        if let me {
            for relation in me.contactRelations {
                let label = relation.label.map { CNLabeledValue<CNContactRelation>.localizedString(forLabel: $0) }
                relations[relation.value.name.lowercased()] = label
            }
        }

        var cards: [ContactCard] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        try store.enumerateContacts(with: request) { contact, _ in
            // Never recommend the user to themselves — their own address turns up in
            // mail threads and notes-to-self.
            if contact.identifier == me?.identifier { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            guard !name.isEmpty else { return }
            let handles = (contact.phoneNumbers.map(\.value.stringValue)
                + contact.emailAddresses.map { $0.value as String })
                .compactMap(Handle.normalize)
            cards.append(ContactCard(
                name: name,
                handles: Array(Set(handles)).sorted(),
                hasBirthday: contact.birthday != nil,
                hasAddress: !contact.postalAddresses.isEmpty,
                hasNickname: !contact.nickname.isEmpty,
                relation: relations[name.lowercased()]
                    ?? relations[contact.givenName.lowercased()]
                    ?? (contact.nickname.isEmpty ? nil : relations[contact.nickname.lowercased()])
            ))
        }
        return cards
    }

    private static func requestAccess(_ store: CNContactStore) throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            store.requestAccess(for: .contacts) { ok, _ in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else {
                // Still undecided means no prompt was ever shown, not a "no".
                throw CNContactStore.authorizationStatus(for: .contacts) == .notDetermined
                    ? AccessError.promptUnavailable : AccessError.denied
            }
        default:
            throw AccessError.denied
        }
    }
}
