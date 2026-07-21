import Foundation

/// Scores clustering output against hand-labelled ground truth.
///
/// The prototype's actual deliverable. Without these numbers, "the clustering looks
/// alright" is an unfalsifiable impression — and the whole point of building this
/// before the UI is to get a number that can veto the approach.
public struct ClusteringEvaluator: Sendable {

    /// Ground truth: face id → the real person's name, hand-assigned.
    public typealias Labels = [UUID: String]

    public struct Report: Sendable, CustomStringConvertible {
        /// Of pairs we merged, the fraction genuinely the same person.
        /// Low precision = strangers welded together = the unacceptable failure.
        public let precision: Double

        /// Of pairs that genuinely are the same person, the fraction we merged.
        /// Low recall = one person split across clusters = tolerable, user-fixable.
        public let recall: Double

        public let f1: Double

        /// Count of clusters containing more than one real person. This is the number to
        /// judge the approach on: it should be zero or near it.
        public let contaminatedClusters: Int

        /// How many clusters the average real person was split across.
        public let averageFragmentation: Double

        public let clusterCount: Int
        public let labelledPeople: Int

        public var description: String {
            """
            Clustering evaluation
            ---------------------
            Precision:              \(String(format: "%.3f", precision))
            Recall:                 \(String(format: "%.3f", recall))
            F1:                     \(String(format: "%.3f", f1))
            Contaminated clusters:  \(contaminatedClusters)  (target: 0)
            Avg fragmentation:      \(String(format: "%.2f", averageFragmentation))  (target: 1.0)
            Clusters / real people: \(clusterCount) / \(labelledPeople)
            """
        }
    }

    public init() {}

    /// Pairwise precision/recall — the standard way to score clustering without needing
    /// a cluster-to-person correspondence. Every pair of faces is a prediction: did we
    /// put them together, and should we have?
    public func evaluate(clusters: [FaceCluster], labels: Labels) -> Report {
        let labelled = clusters.map { cluster in
            cluster.faces.compactMap { labels[$0.id] }
        }

        var truePositives = 0
        var falsePositives = 0

        for names in labelled {
            for i in 0..<names.count {
                for j in (i + 1)..<names.count {
                    if names[i] == names[j] { truePositives += 1 } else { falsePositives += 1 }
                }
            }
        }

        // Every same-person pair that exists in the ground truth.
        var countsByPerson: [String: Int] = [:]
        for name in labels.values { countsByPerson[name, default: 0] += 1 }
        let totalSamePersonPairs = countsByPerson.values.reduce(0) { $0 + ($1 * ($1 - 1)) / 2 }
        let falseNegatives = max(0, totalSamePersonPairs - truePositives)

        let precision = truePositives + falsePositives == 0
            ? 1.0 : Double(truePositives) / Double(truePositives + falsePositives)
        let recall = truePositives + falseNegatives == 0
            ? 1.0 : Double(truePositives) / Double(truePositives + falseNegatives)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)

        let contaminated = labelled.filter { Set($0).count > 1 }.count

        // How many clusters each person's faces landed in.
        var clustersPerPerson: [String: Set<Int>] = [:]
        for (index, names) in labelled.enumerated() {
            for name in names { clustersPerPerson[name, default: []].insert(index) }
        }
        let fragmentation = clustersPerPerson.isEmpty
            ? 0
            : Double(clustersPerPerson.values.reduce(0) { $0 + $1.count })
                / Double(clustersPerPerson.count)

        return Report(
            precision: precision,
            recall: recall,
            f1: f1,
            contaminatedClusters: contaminated,
            averageFragmentation: fragmentation,
            clusterCount: clusters.count,
            labelledPeople: countsByPerson.count
        )
    }

    /// Sweeps merge thresholds so the right value can be read off real data rather than
    /// guessed. Run this once against a labelled sample and hard-code the winner.
    public func sweepThresholds(
        faces: [FaceDescriptor],
        labels: Labels,
        // Squared-Euclidean over normalised vectors is bounded in [0, 4]; in practice
        // anything above ~1.5 merges almost everything, so the useful band is the low end.
        range: [Double] = stride(from: 0.05, through: 1.50, by: 0.05).map { $0 },
        baseParameters: ClusteringParameters = .default
    ) -> [(threshold: Double, report: Report)] {
        range.map { threshold in
            var params = baseParameters
            params.mergeThreshold = threshold
            params.minAssetsToSurface = 1  // evaluate everything, not just surfaced
            let result = FaceClusterer(parameters: params).cluster(faces)
            let all = result.surfaced + result.belowThreshold
            return (threshold, evaluate(clusters: all, labels: labels))
        }
    }
}
