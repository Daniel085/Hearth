import Foundation

/// A group of face descriptors believed to be the same person.
public struct FaceCluster: Sendable, Identifiable {
    public let id: UUID
    public var faces: [FaceDescriptor]

    /// Distinct photos this person appears in. This — not `faces.count` — is the number
    /// that matters for ranking: twelve faces from one burst is far weaker evidence of a
    /// relationship than three faces across three years.
    public var assetCount: Int {
        Set(faces.map(\.assetIdentifier)).count
    }

    public var dateRange: ClosedRange<Date>? {
        let dates = faces.compactMap(\.captureDate).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return first...last
    }

    /// The face best suited to showing the user when asking "who is this?".
    /// Prefers large, front-facing, high-quality captures.
    public var representativeFace: FaceDescriptor? {
        faces.max { a, b in reviewScore(a) < reviewScore(b) }
    }

    private func reviewScore(_ f: FaceDescriptor) -> Double {
        let quality = Double(f.captureQuality ?? 0.5)
        let frontality = 1.0 - min(abs(f.yawDegrees) / 45.0, 1.0)
        return quality * 0.5 + frontality * 0.3 + min(f.relativeSize * 4, 1.0) * 0.2
    }

    public init(id: UUID = UUID(), faces: [FaceDescriptor]) {
        self.id = id
        self.faces = faces
    }
}

public struct ClusteringParameters: Sendable {
    /// Maximum embedding distance for two faces to be considered the same person.
    ///
    /// Units are **squared** Euclidean distance over L2-normalised vectors, matching
    /// Vision's own metric, so the meaningful range is [0, 4] — where 0 is identical and
    /// 2 is orthogonal.
    ///
    /// This value MUST be calibrated against a real library. The default is a
    /// deliberately conservative starting point, not a validated constant: run
    /// `ClusteringEvaluator.sweepThresholds` on labelled data and read the winner off the
    /// curve. See `docs/vision-findings.md` §6.
    public var mergeThreshold: Double

    /// Minimum distinct photos before a cluster is worth showing the user.
    /// One-off faces are overwhelmingly strangers in the background.
    public var minAssetsToSurface: Int

    /// Cap on clusters presented for labelling during onboarding.
    public var maxClustersToSurface: Int

    public var qualityGate: QualityGate

    public init(
        mergeThreshold: Double = 0.62,
        minAssetsToSurface: Int = 3,
        maxClustersToSurface: Int = 20,
        qualityGate: QualityGate = .default
    ) {
        self.mergeThreshold = mergeThreshold
        self.minAssetsToSurface = minAssetsToSurface
        self.maxClustersToSurface = maxClustersToSurface
        self.qualityGate = qualityGate
    }

    public static let `default` = ClusteringParameters()
}

public struct ClusteringResult: Sendable {
    /// Clusters meeting `minAssetsToSurface`, ranked by how worth-labelling they are.
    public let surfaced: [FaceCluster]
    /// Clusters below the threshold — retained, since they may grow later.
    public let belowThreshold: [FaceCluster]
    public let rejectedByQualityGate: Int
    public let totalFacesConsidered: Int
}

/// Agglomerative clustering with average linkage.
///
/// **Why average linkage rather than single linkage:** single linkage (the naive
/// "merge if any pair is close") suffers from chaining — A near B, B near C, C near D
/// silently merges A and D even when they are far apart. For faces this means two
/// genuinely different people get welded together by one ambiguous photo between them,
/// and the user can never un-see it. Average linkage requires the *groups* to be close
/// on the whole, which resists that failure at the cost of occasionally splitting one
/// person into two clusters. That trade is right for us: a split person is a mild
/// annoyance the user can merge, while a merged pair is a wrong, unfixable-looking
/// relationship.
public struct FaceClusterer: Sendable {
    public let parameters: ClusteringParameters

    public init(parameters: ClusteringParameters = .default) {
        self.parameters = parameters
    }

    public func cluster(_ faces: [FaceDescriptor]) -> ClusteringResult {
        let admitted = faces.filter { parameters.qualityGate.admits($0) }
        let rejected = faces.count - admitted.count

        guard !admitted.isEmpty else {
            return ClusteringResult(
                surfaced: [], belowThreshold: [],
                rejectedByQualityGate: rejected, totalFacesConsidered: faces.count
            )
        }

        let n = admitted.count

        // Pairwise distances in a flat row-major matrix of Double, indexed by position.
        // The previous version used [UUID: [UUID: Double]], which meant two dictionary
        // hashes per lookup inside the hottest loop in the program. A flat array turns
        // that into pointer arithmetic.
        var distances = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = admitted[i].embedding.distance(to: admitted[j].embedding)
                distances[i * n + j] = d
                distances[j * n + i] = d
            }
        }

        // Lance-Williams agglomerative clustering.
        //
        // The previous implementation recomputed average linkage between every pair of
        // groups on every merge — O(n⁴) overall, measured at ~360ms for 210 faces, which
        // froze the UI when driven from a slider.
        //
        // Instead, maintain a live group-to-group distance matrix and update it in place
        // after each merge using the Lance-Williams formula for average linkage (UPGMA):
        //
        //     d(i∪j, k) = (|i|·d(i,k) + |j|·d(j,k)) / (|i| + |j|)
        //
        // Each merge then costs O(n) to update rather than O(n³) to recompute. Results
        // are identical — this is the standard formulation of the same algorithm, not an
        // approximation.
        var groupMembers: [[Int]] = (0..<n).map { [$0] }
        var groupDistance = distances       // starts as the point-to-point matrix
        var isActive = [Bool](repeating: true, count: n)
        var activeCount = n

        while activeCount > 1 {
            // Find the closest remaining pair.
            var bestDistance = Double.infinity
            var bestI = -1
            var bestJ = -1

            for i in 0..<n where isActive[i] {
                let rowStart = i * n
                for j in (i + 1)..<n where isActive[j] {
                    let d = groupDistance[rowStart + j]
                    if d < bestDistance {
                        bestDistance = d
                        bestI = i
                        bestJ = j
                    }
                }
            }

            guard bestI >= 0, bestDistance <= parameters.mergeThreshold else { break }

            // Merge j into i, then update i's distances to every other live group.
            let sizeI = Double(groupMembers[bestI].count)
            let sizeJ = Double(groupMembers[bestJ].count)
            let combined = sizeI + sizeJ

            for k in 0..<n where isActive[k] && k != bestI && k != bestJ {
                let updated = (sizeI * groupDistance[bestI * n + k]
                             + sizeJ * groupDistance[bestJ * n + k]) / combined
                groupDistance[bestI * n + k] = updated
                groupDistance[k * n + bestI] = updated
            }

            groupMembers[bestI].append(contentsOf: groupMembers[bestJ])
            groupMembers[bestJ] = []
            isActive[bestJ] = false
            activeCount -= 1
        }

        let clusters = (0..<n)
            .filter { isActive[$0] }
            .map { FaceCluster(faces: groupMembers[$0].map { admitted[$0] }) }
        let ranked = clusters
            .filter { $0.assetCount >= parameters.minAssetsToSurface }
            .sorted { labellingPriority($0) > labellingPriority($1) }

        // Anything ranked past `maxClustersToSurface` still has to go somewhere. An
        // earlier version returned only `prefix(max)` as surfaced and only the
        // below-threshold clusters as the remainder, so clusters that were numerous
        // enough to surface but ranked too low appeared in *neither* list and vanished
        // from the result entirely. Silent data loss — nothing errored, the counts just
        // quietly failed to add up.
        let surfaced = Array(ranked.prefix(parameters.maxClustersToSurface))
        let overflow = Array(ranked.dropFirst(parameters.maxClustersToSurface))
        let tooFewAssets = clusters.filter { $0.assetCount < parameters.minAssetsToSurface }

        return ClusteringResult(
            surfaced: surfaced,
            belowThreshold: overflow + tooFewAssets,
            rejectedByQualityGate: rejected,
            totalFacesConsidered: faces.count
        )
    }

    /// How worth the user's time it is to label this cluster.
    ///
    /// Not simply photo count. Someone photographed across two years matters more than
    /// someone photographed twenty times at one wedding, so recurrence over time is
    /// weighted alongside volume.
    private func labellingPriority(_ cluster: FaceCluster) -> Double {
        let volume = log(Double(cluster.assetCount) + 1)

        var spanBonus = 0.0
        if let range = cluster.dateRange {
            let days = range.upperBound.timeIntervalSince(range.lowerBound) / 86_400
            spanBonus = log(days + 1) / 2
        }

        // Distinct days, not raw photos — collapses bursts.
        let distinctDays = Set(cluster.faces.compactMap { face -> Date? in
            guard let d = face.captureDate else { return nil }
            return Calendar.current.startOfDay(for: d)
        }).count
        let recurrence = log(Double(distinctDays) + 1)

        return volume + spanBonus + recurrence * 1.5
    }
}
