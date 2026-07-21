import Testing
import Foundation
@testable import FaceClustering

// Synthetic descriptors: each "person" is a point in embedding space, each face a
// jittered sample around it. Deterministic — no randomness, so failures are real.

private func face(
    person: [Float],
    jitter: Float,
    asset: String,
    daysAgo: Double = 0,
    quality: Float? = 0.9,
    size: Double = 0.2,
    yaw: Double = 0
) -> FaceDescriptor {
    FaceDescriptor(
        assetIdentifier: asset,
        captureDate: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
        detectionConfidence: 0.95,
        captureQuality: quality,
        relativeSize: size,
        yawDegrees: yaw,
        rollDegrees: 0,
        embedding: Embedding(values: person.map { $0 + jitter })
    )
}

@Test("Distinct, well-separated people do not merge")
func separatePeopleStayApart() {
    let alice: [Float] = [0, 0, 0]
    let bob: [Float] = [10, 10, 10]

    let faces = [
        face(person: alice, jitter: 0.01, asset: "a1"),
        face(person: alice, jitter: 0.02, asset: "a2"),
        face(person: alice, jitter: 0.00, asset: "a3"),
        face(person: bob, jitter: 0.01, asset: "b1"),
        face(person: bob, jitter: 0.02, asset: "b2"),
        face(person: bob, jitter: 0.00, asset: "b3"),
    ]

    let result = FaceClusterer().cluster(faces)
    #expect(result.surfaced.count == 2)
}

@Test("Same person across photos merges into one cluster")
func samePersonMerges() {
    let alice: [Float] = [1, 1, 1]
    let faces = (0..<5).map {
        face(person: alice, jitter: Float($0) * 0.01, asset: "a\($0)")
    }

    let result = FaceClusterer().cluster(faces)
    #expect(result.surfaced.count == 1)
    #expect(result.surfaced.first?.assetCount == 5)
}

@Test("Average linkage resists chaining between two people")
func averageLinkageResistsChaining() {
    // A tight group at 0, a tight group at 1.2, and one ambiguous face between them.
    // Single linkage would chain all three into one cluster; average linkage should not.
    let faces = [
        face(person: [0.0, 0, 0], jitter: 0.0, asset: "a1"),
        face(person: [0.0, 0, 0], jitter: 0.05, asset: "a2"),
        face(person: [0.0, 0, 0], jitter: 0.10, asset: "a3"),
        face(person: [0.6, 0, 0], jitter: 0.0, asset: "mid"),   // the bridge
        face(person: [1.2, 0, 0], jitter: 0.0, asset: "b1"),
        face(person: [1.2, 0, 0], jitter: 0.05, asset: "b2"),
        face(person: [1.2, 0, 0], jitter: 0.10, asset: "b3"),
    ]

    var params = ClusteringParameters.default
    params.mergeThreshold = 0.62
    params.minAssetsToSurface = 1

    let result = FaceClusterer(parameters: params).cluster(faces)
    let all = result.surfaced + result.belowThreshold

    // The two real people must not end up in a single cluster.
    let hasA1 = { (c: FaceCluster) in c.faces.contains { $0.assetIdentifier == "a1" } }
    let hasB1 = { (c: FaceCluster) in c.faces.contains { $0.assetIdentifier == "b1" } }
    #expect(!all.contains { hasA1($0) && hasB1($0) })
}

@Test("Quality gate rejects small, blurry, and extreme-angle faces")
func qualityGateFilters() {
    let p: [Float] = [1, 1, 1]
    let faces = [
        face(person: p, jitter: 0, asset: "ok"),
        face(person: p, jitter: 0, asset: "tiny", size: 0.01),
        face(person: p, jitter: 0, asset: "blurry", quality: 0.1),
        face(person: p, jitter: 0, asset: "profile", yaw: 70),
    ]

    let result = FaceClusterer().cluster(faces)
    #expect(result.rejectedByQualityGate == 3)
    #expect(result.totalFacesConsidered == 4)
}

@Test("Missing capture quality does not reject a face")
func missingQualityIsNotAFailure() {
    let p: [Float] = [2, 2, 2]
    let faces = (0..<3).map {
        face(person: p, jitter: 0, asset: "n\($0)", quality: nil)
    }
    let result = FaceClusterer().cluster(faces)
    #expect(result.rejectedByQualityGate == 0)
}

@Test("Clusters below the photo threshold are held back, not surfaced")
func belowThresholdHeldBack() {
    let alice: [Float] = [0, 0, 0]
    let stranger: [Float] = [20, 20, 20]

    let faces = [
        face(person: alice, jitter: 0.0, asset: "a1"),
        face(person: alice, jitter: 0.01, asset: "a2"),
        face(person: alice, jitter: 0.02, asset: "a3"),
        face(person: stranger, jitter: 0.0, asset: "s1"),
    ]

    let result = FaceClusterer().cluster(faces)
    #expect(result.surfaced.count == 1)
    #expect(result.belowThreshold.count == 1)
}

@Test("Burst photos count once toward assetCount")
func burstsCollapse() {
    let p: [Float] = [3, 3, 3]
    // Five faces, but only two distinct photos.
    let faces = [
        face(person: p, jitter: 0.00, asset: "shot1"),
        face(person: p, jitter: 0.01, asset: "shot1"),
        face(person: p, jitter: 0.02, asset: "shot1"),
        face(person: p, jitter: 0.01, asset: "shot2"),
        face(person: p, jitter: 0.02, asset: "shot2"),
    ]
    let result = FaceClusterer().cluster(faces)
    let all = result.surfaced + result.belowThreshold
    #expect(all.count == 1)
    #expect(all.first?.assetCount == 2)
    #expect(all.first?.faces.count == 5)
}

@Test("Recurring-over-time person outranks a one-event person for labelling")
func recurrenceOutranksVolume() {
    let regular: [Float] = [0, 0, 0]
    let wedding: [Float] = [50, 50, 50]

    // Seen 4 times over a year.
    var faces = (0..<4).map {
        face(person: regular, jitter: Float($0) * 0.01,
             asset: "r\($0)", daysAgo: Double($0) * 90)
    }
    // Photographed 10 times on one day.
    faces += (0..<10).map {
        face(person: wedding, jitter: Float($0) * 0.01,
             asset: "w\($0)", daysAgo: 200)
    }

    let result = FaceClusterer().cluster(faces)
    #expect(result.surfaced.count == 2)

    let top = result.surfaced.first
    #expect(top?.faces.first?.assetIdentifier.hasPrefix("r") == true)
}

@Test("Mismatched embedding dimensions yield infinite distance, not a crash")
func mismatchedDimensionsAreSafe() {
    let a = Embedding(values: [1, 2, 3])
    let b = Embedding(values: [1, 2])
    #expect(a.distance(to: b) == .infinity)
    #expect(Embedding(values: []).distance(to: Embedding(values: [])) == .infinity)
}

@Test("Evaluator reports perfect scores on a clean split")
func evaluatorPerfectCase() {
    let alice: [Float] = [0, 0, 0]
    let bob: [Float] = [9, 9, 9]

    let aFaces = (0..<3).map { face(person: alice, jitter: Float($0) * 0.01, asset: "a\($0)") }
    let bFaces = (0..<3).map { face(person: bob, jitter: Float($0) * 0.01, asset: "b\($0)") }

    var labels: ClusteringEvaluator.Labels = [:]
    aFaces.forEach { labels[$0.id] = "Alice" }
    bFaces.forEach { labels[$0.id] = "Bob" }

    let result = FaceClusterer().cluster(aFaces + bFaces)
    let report = ClusteringEvaluator().evaluate(
        clusters: result.surfaced + result.belowThreshold, labels: labels
    )

    #expect(report.precision == 1.0)
    #expect(report.recall == 1.0)
    #expect(report.contaminatedClusters == 0)
    #expect(report.averageFragmentation == 1.0)
}

@Test("Evaluator detects contamination when two people are merged")
func evaluatorDetectsContamination() {
    // Two people close enough that a loose threshold merges them.
    let alice: [Float] = [0, 0, 0]
    let bob: [Float] = [0.2, 0, 0]

    let aFaces = (0..<3).map { face(person: alice, jitter: Float($0) * 0.01, asset: "a\($0)") }
    let bFaces = (0..<3).map { face(person: bob, jitter: Float($0) * 0.01, asset: "b\($0)") }

    var labels: ClusteringEvaluator.Labels = [:]
    aFaces.forEach { labels[$0.id] = "Alice" }
    bFaces.forEach { labels[$0.id] = "Bob" }

    let result = FaceClusterer().cluster(aFaces + bFaces)
    let report = ClusteringEvaluator().evaluate(
        clusters: result.surfaced + result.belowThreshold, labels: labels
    )

    #expect(report.contaminatedClusters == 1)
    #expect(report.precision < 1.0)
}

@Test("Threshold sweep spans from fully split to fully merged")
func sweepBracketsTheAnswer() {
    let alice: [Float] = [0, 0, 0]
    let bob: [Float] = [1.0, 0, 0]

    let aFaces = (0..<3).map { face(person: alice, jitter: Float($0) * 0.01, asset: "a\($0)") }
    let bFaces = (0..<3).map { face(person: bob, jitter: Float($0) * 0.01, asset: "b\($0)") }

    var labels: ClusteringEvaluator.Labels = [:]
    aFaces.forEach { labels[$0.id] = "Alice" }
    bFaces.forEach { labels[$0.id] = "Bob" }

    let sweep = ClusteringEvaluator().sweepThresholds(faces: aFaces + bFaces, labels: labels)

    // Tight threshold: nothing wrongly merged.
    #expect(sweep.first(where: { $0.threshold <= 0.35 })?.report.contaminatedClusters == 0)
    // Loose threshold: everything merged, so precision must drop.
    #expect(sweep.last?.report.precision ?? 1.0 < 1.0)
}

@Test("Empty input produces an empty result rather than failing")
func emptyInput() {
    let result = FaceClusterer().cluster([])
    #expect(result.surfaced.isEmpty)
    #expect(result.totalFacesConsidered == 0)
}

@Test("Every cluster is returned — none silently dropped by the surfacing cap")
func noClustersVanish() {
    // More distinct people than maxClustersToSurface, all above minAssetsToSurface.
    // An earlier implementation returned only prefix(max) as surfaced and only the
    // too-few-assets clusters as the remainder, so clusters ranked past the cap appeared
    // in neither list and disappeared from the result.
    var faces: [FaceDescriptor] = []
    for person in 0..<25 {
        for shot in 0..<3 {
            faces.append(face(
                person: [Float(person) * 10, 0, 0],
                jitter: Float(shot) * 0.01,
                asset: "p\(person)s\(shot)"
            ))
        }
    }

    var params = ClusteringParameters.default
    params.maxClustersToSurface = 20
    params.minAssetsToSurface = 3

    let result = FaceClusterer(parameters: params).cluster(faces)
    let all = result.surfaced + result.belowThreshold

    #expect(result.surfaced.count == 20)
    #expect(all.count == 25, "expected all 25 people, got \(all.count)")

    // Every input face must appear exactly once somewhere in the output.
    let returned = all.flatMap { $0.faces.map(\.assetIdentifier) }
    #expect(returned.count == faces.count)
    #expect(Set(returned).count == faces.count)
}

@Test("Clustering is deterministic across repeated runs")
func clusteringIsDeterministic() {
    var faces: [FaceDescriptor] = []
    for person in 0..<6 {
        for shot in 0..<4 {
            faces.append(face(
                person: [Float(person) * 2, Float(person), 0],
                jitter: Float(shot) * 0.02,
                asset: "p\(person)s\(shot)"
            ))
        }
    }

    func signature(_ r: ClusteringResult) -> Set<String> {
        Set((r.surfaced + r.belowThreshold).map {
            $0.faces.map(\.assetIdentifier).sorted().joined(separator: ",")
        })
    }

    let first = signature(FaceClusterer().cluster(faces))
    for _ in 0..<5 {
        #expect(signature(FaceClusterer().cluster(faces)) == first)
    }
}
