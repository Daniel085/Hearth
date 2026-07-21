import SwiftUI

/// Reports the pairwise distance distribution from the last scan.
///
/// Answers a question the cluster view can't: when a high merge threshold is needed, is
/// that because the descriptor can't separate faces, or because a particular face
/// genuinely changed? Those have opposite consequences — one kills the approach, the
/// other is a real signal — and they look the same from the outside.
struct DiagnosticsView: View {
    @ObservedObject var scanner: PhotoLibraryScanner
    @State private var stats: PhotoLibraryScanner.DistanceStatistics?
    @State private var computing = true

    var body: some View {
        List {
            if computing {
                Section {
                    HStack {
                        ProgressView()
                        Text("Measuring distances…").foregroundStyle(.secondary)
                    }
                }
            } else if let stats {
                verdictSection(stats)
                contaminationSection
                distributionSection(stats)
                groundTruthSection(stats)
                peopleAlbumSection
            } else {
                Section {
                    Text("Not enough faces from the last scan to measure.")
                        .foregroundStyle(.secondary)
                }
                peopleAlbumSection
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Off the main actor: O(n²) over a few thousand faces would jank the UI.
            let descriptors = scanner.lastDescriptors
            guard !descriptors.isEmpty else {
                computing = false
                return
            }
            let computed = await Task.detached(priority: .userInitiated) {
                await scanner.distanceStatistics()
            }.value
            stats = computed
            computing = false
        }
    }

    @ViewBuilder
    private func verdictSection(_ s: PhotoLibraryScanner.DistanceStatistics) -> some View {
        Section {
            if let separation = s.separation, let diffMedian = s.knownDifferentPersonMedian {
                let verdict = Verdict(separation: separation)

                HStack(spacing: 12) {
                    Image(systemName: verdict.symbol)
                        .font(.title2)
                        .foregroundStyle(verdict.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdict.title).font(.headline)
                        Text(verdict.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabeledContent("Separation", value: String(format: "%.3f", separation))

                // The measured ceiling beats the percentile midpoint: the midpoint is a
                // heuristic over the whole distribution, while this is the largest
                // threshold that provably merges no known-different pair.
                if let ceiling = scanner.safeThresholdCeiling() {
                    LabeledContent("Safe threshold ceiling", value: String(format: "%.1f", ceiling))
                } else {
                    LabeledContent("Safe threshold ceiling", value: "none")
                }
                LabeledContent(
                    "Midpoint estimate",
                    value: String(format: "%.2f", (s.p10 + diffMedian) / 2)
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not enough to judge", systemImage: "questionmark.circle")
                        .font(.headline)
                    Text(insufficientDataMessage(s))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Verdict")
        } footer: {
            Text("Separation is the gap between faces that are probably the same person and faces that are definitely different people. Bigger is better.")
        }
    }

    /// Explains *why* no verdict is available — the two reasons need different fixes.
    private func insufficientDataMessage(
        _ s: PhotoLibraryScanner.DistanceStatistics
    ) -> String {
        let needed = PhotoLibraryScanner.DistanceStatistics.minimumPairsForConfidence
        if s.knownDifferentPersonPairs == 0 {
            return "No photo in this scan contained two faces at once, so there's no reference for what \"different people\" scores. Scan more photos — group shots are what's needed."
        }
        return "Only \(s.knownDifferentPersonPairs) photo\(s.knownDifferentPersonPairs == 1 ? "" : "s") contained two faces at once, and at least \(needed) are needed before that comparison means anything. Scan a larger sample with more group shots."
    }

    private func distributionSection(_ s: PhotoLibraryScanner.DistanceStatistics) -> some View {
        Section {
            LabeledContent("Pairs compared", value: "\(s.pairCount)")
            LabeledContent("Closest", value: String(format: "%.3f", s.minimum))
            LabeledContent("10th percentile", value: String(format: "%.3f", s.p10))
            LabeledContent("Median", value: String(format: "%.3f", s.median))
            LabeledContent("90th percentile", value: String(format: "%.3f", s.p90))
            LabeledContent("Furthest", value: String(format: "%.3f", s.maximum))
        } header: {
            Text("All face pairs")
        } footer: {
            Text("Squared Euclidean distance, 0–4. A wide spread means the descriptor is discriminating; everything bunched together means it isn't.")
        }
    }

    /// Where contamination starts, measured against same-photo pairs.
    @ViewBuilder
    private var contaminationSection: some View {
        let sweep = scanner.contaminationSweep()
        if !sweep.isEmpty {
            Section {
                ForEach(sweep, id: \.threshold) { row in
                    HStack {
                        Text(String(format: "%.1f", row.threshold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .leading)
                        if row.wrongMerges == 0 {
                            Label("clean", systemImage: "checkmark")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                        } else {
                            Text("\(row.wrongMerges) of \(row.totalKnownPairs) wrongly merged")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        Spacer()
                    }
                }
            } header: {
                Text("Contamination by threshold")
            } footer: {
                Text("Two faces in one photo are always different people. This shows how many such pairs each threshold would wrongly merge — a hard ceiling on how high the threshold can safely go.")
            }
        }
    }

    private var peopleAlbumSection: some View {
        Section {
            Text(PhotoLibraryScanner.probeLegacyFacesCollections())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        } header: {
            Text("Photos People album")
        } footer: {
            Text("Confirms that the legacy \"faces\" collection constants are empty — Apple exposes no API for the People & Pets album, so Hearth must build its own groups. See docs/people-album-access.md.")
        }
    }

    private func groundTruthSection(_ s: PhotoLibraryScanner.DistanceStatistics) -> some View {
        Section {
            LabeledContent("Same-photo pairs", value: "\(s.knownDifferentPersonPairs)")
            if let median = s.knownDifferentPersonMedian {
                LabeledContent("Their median distance", value: String(format: "%.3f", median))
            }
        } header: {
            Text("Known different people")
        } footer: {
            Text("Two faces in the same photo are always different people. That gives a free reference for what \"different\" scores, with no labelling needed.")
        }
    }

    private struct Verdict {
        let separation: Double

        // Bands are interpretive, not measured — a starting point for reading the number,
        // not a validated scale.
        var symbol: String {
            if separation > 0.30 { return "checkmark.circle.fill" }
            if separation > 0.12 { return "exclamationmark.triangle.fill" }
            return "xmark.octagon.fill"
        }

        var color: Color {
            if separation > 0.30 { return .green }
            if separation > 0.12 { return .orange }
            return .red
        }

        var title: String {
            if separation > 0.30 { return "Descriptor is separating faces" }
            if separation > 0.12 { return "Weak separation" }
            return "Descriptor is not separating faces"
        }

        var detail: String {
            if separation > 0.30 {
                return "Same-person faces score clearly closer than different-person faces. A high threshold likely reflects a face that genuinely changed, not a broken descriptor."
            }
            if separation > 0.12 {
                return "There is some signal, but the margin is thin. Clustering will be fragile and sensitive to the exact threshold."
            }
            return "Same-person and different-person pairs score about the same. No threshold will separate them — this needs a dedicated face-recognition model."
        }
    }
}
