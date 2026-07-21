import Testing
import Foundation
@testable import FaceClustering

/// Mirrors the statistics logic in `PhotoLibraryScanner.distanceStatistics()`.
///
/// That method lives in the app target (it needs PhotoKit), so it can't be imported here.
/// This duplicates the computation over the same `Embedding` type to prove the maths and
/// the separation heuristic behave — particularly the claim that a wide distribution
/// distinguishes "descriptor works, face changed" from "descriptor is blind".
private struct Stats {
    let p10: Double
    let median: Double
    let p90: Double
    let differentPersonMedian: Double?
    let differentPersonPairs: Int

    /// Mirrors production: below this many same-photo pairs the "median" is an arbitrary
    /// order statistic, so no verdict is offered.
    static let minimumPairs = 8

    var separation: Double? {
        guard differentPersonPairs >= Self.minimumPairs else { return nil }
        return differentPersonMedian.map { $0 - p10 }
    }

    init(faces: [FaceDescriptor]) {
        var all: [Double] = []
        for i in 0..<faces.count {
            for j in (i + 1)..<faces.count {
                let d = faces[i].embedding.distance(to: faces[j].embedding)
                if d.isFinite { all.append(d) }
            }
        }
        all.sort()

        func pct(_ p: Double) -> Double {
            guard !all.isEmpty else { return 0 }
            let idx = Int(Double(all.count - 1) * p)
            return all[max(0, min(all.count - 1, idx))]
        }
        p10 = pct(0.10)
        median = pct(0.50)
        p90 = pct(0.90)

        // Same-photo pairs are definitionally different people.
        var diffs: [Double] = []
        for i in 0..<faces.count {
            for j in (i + 1)..<faces.count
            where faces[i].assetIdentifier == faces[j].assetIdentifier {
                let d = faces[i].embedding.distance(to: faces[j].embedding)
                if d.isFinite { diffs.append(d) }
            }
        }
        differentPersonPairs = diffs.count
        differentPersonMedian = diffs.isEmpty ? nil : diffs.sorted()[diffs.count / 2]
    }
}

private func mk(_ values: [Float], asset: String) -> FaceDescriptor {
    FaceDescriptor(
        assetIdentifier: asset,
        captureDate: Date(timeIntervalSince1970: 1_700_000_000),
        detectionConfidence: 0.95,
        captureQuality: 0.9,
        relativeSize: 0.2,
        yawDegrees: 0,
        rollDegrees: 0,
        embedding: Embedding(values: values)
    )
}

/// Ten photos, each containing person A and person B — so ten same-photo pairs, enough
/// to clear the confidence floor. `spread` controls within-person jitter; `gap` sets how
/// far apart the two people sit.
private func twoPeopleAcrossPhotos(gap: Float, spread: Float) -> [FaceDescriptor] {
    var faces: [FaceDescriptor] = []
    for i in 0..<10 {
        let jitter = Float(i) * spread
        faces.append(mk([jitter, 0, 0], asset: "photo\(i)"))
        faces.append(mk([gap + jitter, 0, 0], asset: "photo\(i)"))
    }
    return faces
}

@Test("A discriminating descriptor shows clear separation")
func healthyDescriptorSeparates() {
    // Tight within person, far between people.
    let stats = Stats(faces: twoPeopleAcrossPhotos(gap: 1.4, spread: 0.01))
    let separation = try! #require(stats.separation)
    #expect(separation > 0.30, "separation was \(separation)")
}

@Test("A blind descriptor shows no separation")
func blindDescriptorDoesNotSeparate() {
    // Within-person spread as large as the between-person gap: the descriptor is not
    // encoding identity, and same-photo pairs score no differently from any other pair.
    let stats = Stats(faces: twoPeopleAcrossPhotos(gap: 0.12, spread: 0.12))
    let separation = try! #require(stats.separation)
    #expect(separation < 0.30, "separation was \(separation)")
}

@Test("Separation is withheld when too few photos contain two faces")
func tooLittleGroundTruthYieldsNil() {
    // Only two same-photo pairs — below the confidence floor, so no verdict.
    let faces = [
        mk([0, 0, 0], asset: "a"), mk([1.0, 0, 0], asset: "a"),
        mk([0.05, 0, 0], asset: "b"), mk([1.05, 0, 0], asset: "b"),
    ]
    #expect(Stats(faces: faces).separation == nil)
}

@Test("Separation is nil when no photo contains two faces")
func noGroundTruthYieldsNil() {
    let faces = [
        mk([0, 0, 0], asset: "a"),
        mk([0.1, 0, 0], asset: "b"),
        mk([1.0, 0, 0], asset: "c"),
    ]
    #expect(Stats(faces: faces).separation == nil)
}

@Test("A changing face widens the spread but keeps separation intact")
func changingFaceWidensSpread() {
    // The baby case: person A drifts steadily over time (a face genuinely changing),
    // while person B stays put. Ten shared photos give the ground truth.
    // The descriptor still works — the distribution is wide, not flat.
    var faces: [FaceDescriptor] = []
    for i in 0..<10 {
        let drift = Float(i) * 0.08   // A changes a lot across the series
        faces.append(mk([drift, 0, 0], asset: "photo\(i)"))
        faces.append(mk([2.2 + Float(i) * 0.005, 0, 0], asset: "photo\(i)"))
    }

    let stats = Stats(faces: faces)
    let separation = try! #require(stats.separation)

    // Same-person distances span a wide range...
    #expect(stats.p90 > stats.p10 * 3)
    // ...yet different-person pairs remain clearly further out.
    #expect(separation > 0.30, "separation was \(separation)")
}

/// Mirrors `PhotoLibraryScanner.contaminationSweep()` / `safeThresholdCeiling()`.
private func safeCeiling(faces: [FaceDescriptor]) -> Double? {
    var knownDifferent: [Double] = []
    for i in 0..<faces.count {
        for j in (i + 1)..<faces.count
        where faces[i].assetIdentifier == faces[j].assetIdentifier {
            let d = faces[i].embedding.distance(to: faces[j].embedding)
            if d.isFinite { knownDifferent.append(d) }
        }
    }
    guard !knownDifferent.isEmpty else { return nil }
    return stride(from: 0.1, through: 1.6, by: 0.1)
        .map { $0 }
        .last { t in knownDifferent.allSatisfy { $0 > t } }
}

@Test("Safe ceiling sits just below the closest known-different pair")
func ceilingRespectsGroundTruth() {
    // Two people 0.55 apart (squared distance 0.3025), sharing every photo.
    let faces = twoPeopleAcrossPhotos(gap: 0.55, spread: 0.001)
    let ceiling = try! #require(safeCeiling(faces: faces))

    // Must not reach the distance at which different people would merge.
    #expect(ceiling < 0.31, "ceiling was \(ceiling)")
    #expect(ceiling >= 0.3, "ceiling was \(ceiling)")
}

@Test("No safe ceiling when different people are already too close")
func noCeilingWhenContaminatedEverywhere() {
    // Different people separated by less than the tightest threshold tested.
    let faces = twoPeopleAcrossPhotos(gap: 0.15, spread: 0.001)
    #expect(safeCeiling(faces: faces) == nil)
}

@Test("Ceiling is nil without ground truth")
func ceilingNilWithoutGroundTruth() {
    let faces = [
        mk([0, 0, 0], asset: "a"),
        mk([1.0, 0, 0], asset: "b"),
    ]
    #expect(safeCeiling(faces: faces) == nil)
}
