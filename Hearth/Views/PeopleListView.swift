import SwiftUI

/// Everyone in Hearth, including people the Launchpad is currently hiding.
///
/// The Launchpad only shows who needs attention *today* — muted people and anyone
/// recently contacted are deliberately absent. Without this screen there would be no way
/// to reach them to change a tier or unmute, which would make muting a one-way door.
struct PeopleListView: View {
    @StateObject private var store = PersonStore()
    @State private var people: [CDPerson] = []
    @State private var showingAddPerson = false

    var body: some View {
        Group {
            if people.isEmpty {
                ContentUnavailableView {
                    Label("No one here yet", systemImage: "person.2")
                } description: {
                    Text("Add people from Contacts, by name, or by scanning your photos.")
                } actions: {
                    Button("Add someone") { showingAddPerson = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(people, id: \.id) { person in
                        NavigationLink {
                            PersonDetailView(personID: person.id)
                        } label: {
                            PersonRow(person: person, store: store)
                        }
                    }
                }
            }
        }
        .navigationTitle("People")
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
            AddPersonView { reload() }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        people = store.allPeople()
    }
}

struct PersonRow: View {
    let person: CDPerson
    let store: PersonStore

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.tint.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(initials)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName ?? "Unknown")
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if person.isMuted {
                Image(systemName: "bell.slash")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var subtitle: String {
        let tier = RelationshipTier(rawValue: person.tier) ?? .close
        let photos = store.photoCount(for: person)
        return photos > 0 ? "\(tier.label) · \(photos) photos" : tier.label
    }

    private var initials: String {
        (person.displayName ?? "?")
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}
