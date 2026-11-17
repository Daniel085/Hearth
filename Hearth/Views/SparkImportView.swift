import SwiftUI

/// Reviews a Hearth Spark file from the user's Mac, saves the chosen people, deletes
/// the file, and shows what was kept.
///
/// Nothing is saved until the user taps Add. Cancelling deletes the file too: it was
/// sent to be imported, and leaving it in Hearth's inbox would keep data nobody asked
/// to keep.
struct SparkImportView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PersonStore()

    @State private var file: SparkFile?
    @State private var loadError: String?
    @State private var matches: [Int: String] = [:]
    @State private var contactsAllowed = false
    @State private var selected: Set<Int> = []
    @State private var existing: Set<String> = []
    @State private var summary: Summary?

    struct Summary {
        var added: Int
        var updated: Int
        var lastContact: Int
        var linked: Int
        var fileDeleted: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    kept(summary)
                } else if let file {
                    review(file)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Can't open this file", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(summary == nil ? "From your Mac" : "Imported")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(summary == nil && file != nil)
        .task { load() }
    }

    // MARK: - Review

    private func review(_ file: SparkFile) -> some View {
        List {
            Section {
                Text("Hearth Spark suggested these people from your Mac. Untick anyone you don't want. Nothing is saved until you tap Add.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(SparkTier.allCases, id: \.self) { tier in
                let indices = file.people.indices.filter { file.people[$0].suggestedTier == tier }
                if !indices.isEmpty {
                    Section(tier.label) {
                        ForEach(indices, id: \.self) { index in
                            row(file.people[index], index: index)
                        }
                    }
                }
            }

            Section {
                Group {
                    if contactsAllowed {
                        Label("\(matches.count) of \(file.people.count) matched to your contacts.", systemImage: "person.crop.circle.badge.checkmark")
                    } else {
                        Label("Hearth doesn't have access to your contacts, so these people won't be linked to contact cards. You can link anyone later.", systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } footer: {
                Text("Hearth keeps each person's name and closeness, and roughly when you were last in touch. The reasons shown here and the file itself are not kept.")
            }
        }
    }

    private func row(_ person: SparkPerson, index: Int) -> some View {
        let isSelected = selected.contains(index)
        return Button {
            if isSelected { selected.remove(index) } else { selected.insert(index) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(person.name)
                        if existing.contains(person.name.lowercased()) {
                            Text("In Hearth").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !person.reasons.isEmpty {
                        Text(person.reasons.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Kept

    private func kept(_ summary: Summary) -> some View {
        List {
            Section {
                Text(summary.added == 1 ? "Added 1 person." : "Added \(summary.added) people.")
                    .font(.headline)
                if summary.updated > 0 {
                    Text("\(summary.updated) already in Hearth kept the closeness you'd given them.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("What Hearth kept") {
                Label("Names and closeness for \(summary.added + summary.updated) people", systemImage: "person.2")
                if summary.lastContact > 0 {
                    Label("Roughly when you were last in touch, for \(summary.lastContact)", systemImage: "calendar")
                }
                if summary.linked > 0 {
                    Label("Links to \(summary.linked) contact cards", systemImage: "person.crop.circle")
                }
            }
            Section("Not kept") {
                Label("The reasons, and the codes used to match contacts", systemImage: "xmark.circle")
                Label(
                    summary.fileDeleted
                        ? "The file from your Mac — deleted from this iPhone"
                        : "The file from your Mac couldn't be deleted. Remove it from Hearth's folder in the Files app.",
                    systemImage: summary.fileDeleted ? "trash" : "exclamationmark.triangle"
                )
            }
        }
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if summary != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    SparkImport.delete(url)
                    dismiss()
                }
            }
            if file != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Add" : "Add \(selected.count)") { add() }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func load() {
        guard file == nil, loadError == nil else { return }
        do {
            let loaded = try SparkImport.load(url)
            let contacts = SparkImport.phoneContactsIfAllowed()
            contactsAllowed = contacts != nil
            matches = contacts.map { SparkImport.match(loaded, against: $0) } ?? [:]
            existing = store.existingNames()
            selected = Set(loaded.people.indices)
            file = loaded
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? "It isn't a Hearth Spark file, or it's damaged. Make a new one on your Mac."
            SparkImport.delete(url)
        }
    }

    private func add() {
        guard let file else { return }
        let chosen = file.people.indices.filter(selected.contains)
        let wasInHearth = chosen.filter { existing.contains(file.people[$0].name.lowercased()) }.count
        let added = store.importSpark(chosen.map { (file.people[$0], matches[$0]) })
        summary = Summary(
            added: added,
            updated: wasInHearth,
            lastContact: chosen.filter { file.people[$0].lastContactMonth != nil }.count,
            linked: chosen.filter { matches[$0] != nil }.count,
            fileDeleted: SparkImport.delete(url)
        )
    }
}

/// Lets a received file drive `.sheet(item:)`.
struct IncomingSpark: Identifiable {
    let url: URL
    var id: URL { url }
}
