import SwiftUI

/// Post-scan summary, cluster grid, and the threshold tuner.
///
/// This screen carries a dual purpose right now: it is the beginning of the real
/// onboarding flow ("who are these people?"), and it is the instrument that answers
/// whether Vision feature prints can distinguish faces at all.
struct ResultsView: View {
    @ObservedObject var scanner: PhotoLibraryScanner
    let summary: PhotoLibraryScanner.ScanSummary

    @State private var threshold: Double = ClusteringParameters.default.mergeThreshold
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var nameTarget: Set<UUID>?

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Photos scanned", value: "\(summary.photosScanned)")
                LabeledContent("Faces detected", value: "\(summary.facesDetected)")
                LabeledContent("Passed quality gate", value: "\(summary.facesAdmitted)")
                LabeledContent("People found", value: "\(summary.clustersSurfaced)")
                LabeledContent(
                    "Crop padding",
                    value: scanner.cropPadding.formatted(.percent.precision(.fractionLength(0)))
                )
                LabeledContent("Scan time", value: String(format: "%.1fs", summary.duration))
                if summary.photosScanned > 0 {
                    LabeledContent(
                        "Per photo",
                        value: String(format: "%.0f ms", summary.duration / Double(summary.photosScanned) * 1000)
                    )
                }
            } header: {
                Text("Scan summary")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Merge threshold")
                        Spacer()
                        Text(String(format: "%.2f", threshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $threshold, in: 0.05...1.50, step: 0.05)
                        .onChange(of: threshold) { _, newValue in
                            scanner.reclusterDebounced(mergeThreshold: newValue)
                        }
                    Text("Lower splits people apart; higher merges them together. Re-grouping is instant — no need to rescan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tuning")
            } footer: {
                Text("If two different people share a group, the threshold is too high. If one person appears twice, it's too low.")
            }

            Section {
                NavigationLink {
                    DiagnosticsView(scanner: scanner)
                } label: {
                    Label("Distance diagnostics", systemImage: "ruler")
                }
            } footer: {
                Text("Measures whether the descriptor can actually tell faces apart — worth checking if you needed a high threshold.")
            }

            Section {
                if scanner.clusters.isEmpty {
                    Text("No groups met the threshold.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scanner.clusters) { cluster in
                        if isSelecting {
                            Button {
                                toggle(cluster.id)
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(cluster.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(cluster.id)
                                                         ? AnyShapeStyle(.tint)
                                                         : AnyShapeStyle(.secondary))
                                    ClusterRow(cluster: cluster)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                ClusterDetailView(cluster: cluster)
                            } label: {
                                ClusterRow(
                                    cluster: cluster,
                                    personName: scanner.personName(forCluster: cluster.id)
                                )
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Face groups")
                    Spacer()
                    if !scanner.clusters.isEmpty {
                        Button(isSelecting ? "Done" : "Name someone") {
                            if isSelecting { selected.removeAll() }
                            isSelecting.toggle()
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                }
            } footer: {
                if isSelecting {
                    Text("Select every group showing the same person — a face that changes over time will appear as several. They stay separate; they're just recorded as the same person.")
                } else {
                    Text("Groups are ranked by how often someone recurs over time, not by raw photo count. One person may have several groups.")
                }
            }

            if isSelecting && !selected.isEmpty {
                Section {
                    Button {
                        nameTarget = selected
                    } label: {
                        Text("Name \(selected.count) group\(selected.count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }

            if !scanner.namedPeople.isEmpty {
                Section("People") {
                    ForEach(scanner.namedPeople, id: \.name) { entry in
                        LabeledContent(
                            entry.name,
                            value: "\(entry.groupCount) group\(entry.groupCount == 1 ? "" : "s")"
                        )
                    }
                }
            }
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $nameTarget) { target in
            NamePersonSheet(
                groupCount: target.count,
                existingNames: scanner.namedPeople.map(\.name)
            ) { name in
                scanner.assign(clusterIDs: target, toPersonNamed: name)
                selected.removeAll()
                isSelecting = false
                nameTarget = nil
            } onCancel: {
                nameTarget = nil
            }
        }
    }
}

/// Lets `Set<UUID>` drive a `.sheet(item:)`.
extension Set: @retroactive Identifiable where Element == UUID {
    public var id: String { sorted(by: { $0.uuidString < $1.uuidString })
        .map(\.uuidString).joined() }
}

/// Names the selected face groups, offering existing people so a second group can be
/// added to someone already named — the common case for a face that changed over time.
struct NamePersonSheet: View {
    let groupCount: Int
    let existingNames: [String]
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Who is this?")
                } footer: {
                    Text("\(groupCount) face group\(groupCount == 1 ? "" : "s") will be linked to this person.")
                }

                if !existingNames.isEmpty {
                    Section {
                        ForEach(existingNames, id: \.self) { existing in
                            Button(existing) { name = existing }
                        }
                    } header: {
                        Text("Already named")
                    } footer: {
                        Text("Pick someone to add these groups to them.")
                    }
                }
            }
            .navigationTitle("Name person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ClusterRow: View {
    let cluster: FaceCluster
    var personName: String? = nil
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                if let personName {
                    Text(personName)
                        .font(.body.weight(.semibold))
                    Text("\(cluster.assetCount) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(cluster.assetCount) photos")
                        .font(.body.weight(.medium))
                }
                if let range = cluster.dateRange {
                    Text(rangeDescription(range))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard thumbnail == nil, let face = cluster.representativeFace else { return }
            thumbnail = await FaceThumbnailLoader.thumbnail(for: face)
        }
    }

    private func rangeDescription(_ range: ClosedRange<Date>) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        let start = f.string(from: range.lowerBound)
        let end = f.string(from: range.upperBound)
        return start == end ? start : "\(start) – \(end)"
    }
}

/// Every face in a cluster, so contamination is visible at a glance.
///
/// The single most useful validation view: if two different people appear in this grid,
/// the approach is failing and no amount of threshold tuning fixes it.
struct ClusterDetailView: View {
    let cluster: FaceCluster

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(cluster.faces) { face in
                    FaceThumbnail(face: face)
                }
            }
            .padding()
        }
        .navigationTitle("\(cluster.faces.count) faces")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FaceThumbnail: View {
    let face: FaceDescriptor
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil else { return }
            image = await FaceThumbnailLoader.thumbnail(for: face, size: 120)
        }
    }
}
