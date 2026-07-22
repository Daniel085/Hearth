import SwiftUI
import Contacts
import ContactsUI

/// Adds people without touching the photo library.
///
/// Photos are one way to find the people who matter, not the only one — and not a
/// requirement. Everything downstream (cadence, birthdays, scoring, the Launchpad) works
/// with no photo access at all; scanning only *seeds* the list faster.
///
/// This also happens to be the strongest privacy mitigation available: an app that is
/// fully usable without ever generating a faceprint is a far weaker target under BIPA
/// than one where scanning is step one of onboarding. See `docs/core-ml-comparison.md` §3.
struct AddPersonView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PersonStore()

    @State private var manualName = ""
    @State private var showingContactPicker = false
    @State private var contactsDenied = false

    var onAdded: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        requestContactsThenPick()
                    } label: {
                        Label("Choose from Contacts", systemImage: "person.crop.circle")
                    }
                } header: {
                    Text("From your contacts")
                } footer: {
                    if contactsDenied {
                        Text("Hearth doesn't have access to Contacts. You can still add people by name below, or enable access in Settings.")
                    } else {
                        Text("Brings across their name and birthday. Nothing is uploaded.")
                    }
                }

                Section {
                    TextField("Name", text: $manualName)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                    Button("Add") {
                        store.findOrCreatePerson(named: manualName)
                        manualName = ""
                        onAdded()
                        dismiss()
                    }
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("By name")
                } footer: {
                    Text("You can add details later.")
                }
            }
            .navigationTitle("Add someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingContactPicker) {
                ContactPicker { contact in
                    add(contact)
                    showingContactPicker = false
                    onAdded()
                    dismiss()
                }
            }
        }
    }

    private func requestContactsThenPick() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            showingContactPicker = true
        case .notDetermined:
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                Task { @MainActor in
                    if granted { showingContactPicker = true } else { contactsDenied = true }
                }
            }
        default:
            // Denied or restricted. Not a dead end — the name field still works.
            contactsDenied = true
        }
    }

    private func add(_ contact: CNContact) {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallback = contact.organizationName
        let display = name.isEmpty ? fallback : name
        guard !display.isEmpty else { return }

        var birthday: Date?
        if let components = contact.birthday {
            var withYear = components
            // Contacts often omit the year; any year works since only month/day are used.
            if withYear.year == nil { withYear.year = 2000 }
            birthday = Calendar.current.date(from: withYear)
        }

        store.findOrCreatePerson(
            named: display,
            contactIdentifier: contact.identifier,
            birthday: birthday
        )
    }
}

/// Thin wrapper over `CNContactPickerViewController`.
///
/// The picker runs out-of-process: Hearth receives only the contact the user picked, and
/// never gains access to the rest of the address book. That is a stronger privacy
/// position than requesting full Contacts access, so it is preferred wherever possible.
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (CNContact) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact) -> Void
        init(onPick: @escaping (CNContact) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }
    }
}
