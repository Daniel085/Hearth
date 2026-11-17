import Contacts
import Foundation

/// Opening a Hearth Spark file sent from the user's Mac.
///
/// The file format and handle normalization are compiled from the Mac app's own source
/// (`mac/HearthSpark/Sources/HearthSparkCore`), so the two can't drift apart.
///
/// Same promise as on the Mac: the user reviews before anything is saved, Hearth keeps
/// the minimum, and the received file is deleted afterwards.
enum SparkImport {

    /// Reads a received file. iOS copies AirDropped files into the app's inbox
    /// (`LSSupportsOpeningDocumentsInPlace` is off), so no security scope is needed —
    /// but one is honoured if the file came from elsewhere.
    static func load(_ url: URL) throws -> SparkFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try SparkFile.decode(Data(contentsOf: url))
    }

    /// Deletes the received file, and reports whether it's really gone.
    @discardableResult
    static func delete(_ url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// A contact on this phone, reduced to what matching needs.
    struct PhoneContact: Equatable {
        let identifier: String
        let handles: [String]   // normalized, via `Handle.normalize`
    }

    /// For each person in the file, the contact on this phone with a matching phone
    /// number or email, by index into `file.people`.
    ///
    /// The file carries salted hashes, so the phone hashes its own contacts' numbers
    /// with the file's salt and compares. Numbers never travel in the clear.
    static func match(_ file: SparkFile, against contacts: [PhoneContact]) -> [Int: String] {
        var byKey: [String: String] = [:]
        for contact in contacts {
            for handle in contact.handles {
                let key = MatchKey.hash(handle, salt: file.salt)
                // First contact wins if two share a number, as households sometimes do.
                if byKey[key] == nil { byKey[key] = contact.identifier }
            }
        }
        var matches: [Int: String] = [:]
        for (index, person) in file.people.enumerated() {
            if let id = person.matchKeys.lazy.compactMap({ byKey[$0] }).first {
                matches[index] = id
            }
        }
        return matches
    }

    /// The phone's contacts, if Hearth already has access — or nil.
    ///
    /// Never asks. Hearth normally adds people through the system contact picker, which
    /// needs no access at all; it would be wrong to demand full access just to link a
    /// few suggestions. Without it, people are still imported, just unlinked.
    static func phoneContactsIfAllowed() -> [PhoneContact]? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var contacts: [PhoneContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let handles = (contact.phoneNumbers.map(\.value.stringValue)
                + contact.emailAddresses.map { $0.value as String })
                .compactMap(Handle.normalize)
            if !handles.isEmpty {
                contacts.append(PhoneContact(identifier: contact.identifier, handles: handles))
            }
        }
        return contacts
    }
}
