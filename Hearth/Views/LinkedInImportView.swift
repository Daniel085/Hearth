import SwiftUI
import UniformTypeIdentifiers

/// Picks people out of a LinkedIn `Connections.csv` export.
///
/// A picker, not a bulk import. A LinkedIn network is hundreds of loose ties; Hearth is
/// for the few dozen people worth keeping up with. Importing everyone would bury them
/// and make the Launchpad nag about acquaintances, so nothing is selected by default.
struct LinkedInImportView: View {
    @StateObject private var store = PersonStore()

    @State private var connections: [LinkedInConnection] = []
    @State private var suggestions: [LinkedInConnection.ID: LinkedInSuggestion] = [:]
    @State private var existing: Set<String> = []
    @State private var selected: Set<LinkedInConnection.ID> = []
    @State private var search = ""
    @State private var tier: RelationshipTier = .keptWarm
    @State private var showingFilePicker = false
    @State private var errorMessage: String?

    var onImported: () -> Void

    var body: some View {
        Group {
            if connections.isEmpty {
                instructions
            } else {
                picker
            }
        }
        .navigationTitle("From LinkedIn")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder, .commaSeparatedText, .plainText]
        ) { result in
            load(result)
        }
    }

    // MARK: - Before a file is chosen

    private var instructions: some View {
        Form {
            Section {
                Label("On LinkedIn, open Settings → Data privacy → Get a copy of your data.", systemImage: "1.circle")
                Label("Request the larger data archive. It includes the endorsements and job history Hearth uses for suggestions.", systemImage: "2.circle")
                Label("LinkedIn emails a download link, usually within minutes. Save the archive to Files and tap it to unzip.", systemImage: "3.circle")
            } header: {
                Text("Get your connections")
            } footer: {
                Text("Hearth reads the export on your phone and never signs in to LinkedIn. You choose who to add.")
            }

            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    Label("Choose export folder", systemImage: "folder")
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("Choosing the whole folder lets Hearth suggest people from endorsements, recommendations and shared employers. Connections.csv on its own works too.")
                }
            }
        }
    }

    // MARK: - After

    private var picker: some View {
        List {
            Section {
                Picker("Add as", selection: $tier) {
                    ForEach(RelationshipTier.allCases, id: \.self) { tier in
                        Text(tier.label).tag(tier)
                    }
                }
            } footer: {
                Text("People already in Hearth keep their closeness.")
            }

            let (suggested, others) = partitioned
            if !suggested.isEmpty {
                Section {
                    ForEach(suggested) { row($0) }
                } header: {
                    Text("Suggested")
                } footer: {
                    Text("From endorsements, recommendations and employers you share. LinkedIn doesn't export messages, so people you only talk to there won't show here.")
                }
            }
            Section {
                ForEach(others) { row($0) }
            } header: {
                Text(suggested.isEmpty ? "\(connections.count) connections" : "Everyone else")
            }
        }
        .searchable(text: $search, prompt: "Search name or company")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                    importSelected()
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private func row(_ connection: LinkedInConnection) -> some View {
        let isSelected = selected.contains(connection.id)
        let alreadyIn = existing.contains(connection.fullName.lowercased())
        return Button {
            if isSelected { selected.remove(connection.id) } else { selected.insert(connection.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.fullName)
                        .foregroundStyle(.primary)
                    if let work = connection.workSummary {
                        Text(work)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let reasons = suggestions[connection.id]?.reasons, !reasons.isEmpty {
                        Text(reasons.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if alreadyIn {
                    Text("In Hearth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Whole row is the hit target, not just the text and icon.
            .contentShape(Rectangle())
        }
        // Default list button styling tints every label the accent colour.
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filtered: [LinkedInConnection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return connections }
        return connections.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
                || ($0.company?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Suggested people strongest first, then everyone else alphabetically.
    private var partitioned: (suggested: [LinkedInConnection], others: [LinkedInConnection]) {
        var suggested: [LinkedInConnection] = []
        var others: [LinkedInConnection] = []
        for connection in filtered {
            if suggestions[connection.id] != nil { suggested.append(connection) } else { others.append(connection) }
        }
        suggested.sort { (suggestions[$0.id]?.score ?? 0) > (suggestions[$1.id]?.score ?? 0) }
        return (suggested, others)
    }

    // MARK: - Actions

    private func load(_ result: Result<URL, Error>) {
        errorMessage = nil
        do {
            let url = try result.get()
            // Files from the document picker live outside the sandbox.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // A folder is the unzipped export: read connections plus the signal files.
            // A lone CSV gives connections only, with no suggestions.
            let csv: URL
            var signals = LinkedInSignals()
            if url.hasDirectoryPath {
                guard let found = LinkedInExport.find("Connections.csv", in: url) else {
                    errorMessage = "That folder has no Connections.csv. Choose the unzipped LinkedIn export."
                    return
                }
                csv = found
                signals = LinkedInSignals.read(fromExportFolder: url)
            } else {
                csv = url
            }

            let parsed = try LinkedInConnectionsParser.parse(data: Data(contentsOf: csv))
            guard !parsed.isEmpty else {
                errorMessage = "That file has no connections in it."
                return
            }
            existing = store.existingNames()
            let now = Date()
            suggestions = Dictionary(uniqueKeysWithValues: parsed.compactMap { connection in
                signals.suggestion(for: connection, now: now).map { (connection.id, $0) }
            })
            connections = parsed.sorted {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        } catch let error as LinkedInImportError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = LinkedInImportError.unreadable.errorDescription
        }
    }

    private func importSelected() {
        let chosen = connections.filter { selected.contains($0.id) }
        store.importLinkedInConnections(chosen, tier: tier)
        onImported()
    }
}
