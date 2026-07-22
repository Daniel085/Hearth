import SwiftUI
import Contacts
import UIKit

/// The Launchpad — who needs attention, why, and what to do about it.
///
/// A deliberately quiet surface. You come here to start a conversation; it does not
/// interrupt you. Cards state their reason plainly and offer a direct action.
struct LaunchpadView: View {
    @StateObject private var model = LaunchpadModel()
    @State private var showingAddPerson = false

    var body: some View {
        Group {
            if model.people.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.people) { person in
                        LaunchpadCard(person: person) { action in
                            model.perform(action, for: person)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddPerson = true
                } label: {
                    Label("Add someone", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPerson) {
            AddPersonView { model.refresh() }
        }
        .alert(
            "Can't do that yet",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .onAppear { model.refresh() }
    }

    /// Two different empty states: nobody added yet, versus nobody due today.
    /// Collapsing them would leave a new user staring at "nothing to do" with no way in.
    @ViewBuilder
    private var emptyState: some View {
        if model.isEmpty {
            ContentUnavailableView {
                Label("No one here yet", systemImage: "person.badge.plus")
            } description: {
                Text("Add the people you want to stay close to. You can pick them from Contacts, type a name, or find them in your photos.")
            } actions: {
                Button("Add someone") { showingAddPerson = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Nobody needs you today", systemImage: "checkmark.circle")
            } description: {
                Text("Hearth will let you know when someone's worth reaching out to.")
            }
        }
    }
}

/// One person, one reason, one action.
struct LaunchpadCard: View {
    let person: ScoredPerson
    let onAction: (LaunchpadAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(initials)
                            .font(.headline)
                            .foregroundStyle(.tint)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.displayName)
                        .font(.headline)
                    if let headline = person.headline {
                        Text(headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(LaunchpadAction.allCases, id: \.self) { action in
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.label, systemImage: action.symbol)
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("\(action.label) \(person.displayName)")
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var initials: String {
        person.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

enum LaunchpadAction: CaseIterable, Hashable {
    case call, message, email, snooze

    var label: String {
        switch self {
        case .call: "Call"
        case .message: "Message"
        case .email: "Email"
        case .snooze: "Not now"
        }
    }

    var symbol: String {
        switch self {
        case .call: "phone"
        case .message: "message"
        case .email: "envelope"
        case .snooze: "clock"
        }
    }
}

@MainActor
final class LaunchpadModel: ObservableObject {
    @Published private(set) var people: [ScoredPerson] = []
    @Published var actionError: String?

    private let scorer = RelationshipScorer()
    private let store = PersonStore()
    private let launcher = ContactLauncher()

    var isEmpty: Bool { store.allPeople().isEmpty }

    func refresh() {
        people = scorer.rank(store.scoringInputs(), now: Date())
    }

    func perform(_ action: LaunchpadAction, for scored: ScoredPerson) {
        guard let person = store.allPeople().first(where: { $0.id == scored.personID }) else {
            return
        }

        switch action {
        case .snooze:
            // Not an interaction — the user chose *not* to reach out. Recording contact
            // here would be a lie that suppresses this person for 48 hours.
            store.setMuted(true, for: person)
            refresh()

        case .call, .message, .email:
            Task {
                let outcome = await launcher.launch(action, for: person)
                switch outcome {
                case .launched(let kind):
                    // We know Hearth opened the app, not that anything was sent or
                    // answered. Recorded at reduced confidence for exactly that reason.
                    store.recordInteraction(with: person, kind: kind, source: .launchpadAction)
                    refresh()
                case .missingDetail(let what):
                    actionError = "No \(what) saved for \(person.displayName ?? "this person")."
                case .cannotOpen:
                    actionError = "This device can't open that app."
                }
            }
        }
    }
}

/// Opens the native app for a contact action.
///
/// Deliberately reports *why* it failed rather than silently doing nothing. A button
/// that appears to work and doesn't is worse than one that explains itself.
@MainActor
struct ContactLauncher {
    enum Outcome {
        case launched(InteractionKind)
        case missingDetail(String)
        case cannotOpen
    }

    func launch(_ action: LaunchpadAction, for person: CDPerson) async -> Outcome {
        guard let identifier = person.contactIdentifier else {
            return .missingDetail(action == .email ? "email address" : "phone number")
        }

        let details = ContactDetails.fetch(identifier: identifier)

        let url: URL?
        let kind: InteractionKind
        switch action {
        case .call:
            guard let phone = details?.phone else { return .missingDetail("phone number") }
            url = URL(string: "tel://\(phone.filter { !$0.isWhitespace })")
            kind = .call
        case .message:
            guard let phone = details?.phone else { return .missingDetail("phone number") }
            url = URL(string: "sms://\(phone.filter { !$0.isWhitespace })")
            kind = .message
        case .email:
            guard let email = details?.email else { return .missingDetail("email address") }
            url = URL(string: "mailto:\(email)")
            kind = .email
        case .snooze:
            return .cannotOpen
        }

        guard let url, UIApplication.shared.canOpenURL(url) else { return .cannotOpen }
        await UIApplication.shared.open(url)
        return .launched(kind)
    }
}

/// Fetches just the phone and email for one contact, on demand.
///
/// Nothing is cached in Hearth's own store. Contact details live in Contacts, which is
/// already the user's system of record — copying them would mean holding personal data
/// with no benefit and an extra deletion obligation.
private enum ContactDetails {
    static func fetch(identifier: String) -> (phone: String?, email: String?)? {
        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        guard let contact = try? CNContactStore().unifiedContact(
            withIdentifier: identifier, keysToFetch: keys
        ) else { return nil }

        return (
            phone: contact.phoneNumbers.first?.value.stringValue,
            email: contact.emailAddresses.first?.value as String?
        )
    }
}
