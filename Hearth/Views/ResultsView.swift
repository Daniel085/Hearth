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
    @State private var showingDiagnostics = false

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
                        NavigationLink {
                            ClusterDetailView(cluster: cluster)
                        } label: {
                            ClusterRow(cluster: cluster)
                        }
                    }
                }
            } header: {
                Text("People found")
            } footer: {
                Text("Groups are ranked by how often someone recurs over time, not by raw photo count.")
            }
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ClusterRow: View {
    let cluster: FaceCluster
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
                Text("\(cluster.assetCount) photos")
                    .font(.body.weight(.medium))
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
