import Foundation

/// A detected face reduced to the minimum needed for clustering.
///
/// Deliberately free of Vision and PhotoKit types so the clustering algorithm can be
/// unit-tested on any platform with synthetic distances. `VisionFaceExtractor` produces
/// these from real photos; the tests produce them from fixtures.
public struct FaceDescriptor: Sendable, Identifiable {
    public let id: UUID

    /// `PHAsset.localIdentifier` of the source photo. We never copy pixels.
    public let assetIdentifier: String

    public let captureDate: Date?

    /// Vision's face-detection confidence, 0–1.
    public let detectionConfidence: Float

    /// Vision's capture-quality score, if available. Low-quality faces cluster badly,
    /// so this is used to gate what enters clustering at all.
    public let captureQuality: Float?

    /// Face size as a fraction of the image's smaller dimension. Tiny background faces
    /// produce unreliable descriptors regardless of their quality score.
    public let relativeSize: Double

    /// Head pose in degrees. Extreme angles are the dominant cause of a single person
    /// splitting into several clusters.
    public let yawDegrees: Double
    public let rollDegrees: Double

    /// Opaque embedding used for similarity. See `VisionFaceExtractor` for the important
    /// caveat about what this actually encodes.
    public let embedding: Embedding

    public init(
        id: UUID = UUID(),
        assetIdentifier: String,
        captureDate: Date?,
        detectionConfidence: Float,
        captureQuality: Float?,
        relativeSize: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        embedding: Embedding
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.captureDate = captureDate
        self.detectionConfidence = detectionConfidence
        self.captureQuality = captureQuality
        self.relativeSize = relativeSize
        self.yawDegrees = yawDegrees
        self.rollDegrees = rollDegrees
        self.embedding = embedding
    }
}

/// A distance-comparable descriptor.
///
/// Backed by a plain `[Float]` so tests can construct one directly. In production the
/// values come from Vision, and `distance` mirrors the metric Vision itself uses.
public struct Embedding: Sendable, Equatable {
    public let values: [Float]

    public init(values: [Float]) {
        self.values = values
    }

    /// **Squared** Euclidean distance, matching `FeaturePrintObservation.distance(to:)`.
    ///
    /// Vision's metric is squared Euclidean, not Euclidean — measured empirically against
    /// real feature prints, exact to six decimal places across every pair tested. Taking
    /// the square root here would make every calibrated threshold wrong by a nonlinear
    /// factor, which is a silent failure: clustering would still run and still produce
    /// plausible-looking groups, just with the wrong merge boundary.
    /// Locked in by `visionDistanceMatchesOurMetric` in the test suite.
    ///
    /// Vision's vectors are L2-normalised (768 floats, norm ≈ 1.0), so this equals
    /// 2 × cosine distance and is bounded in [0, 4] — useful when reasoning about
    /// threshold ranges.
    ///
    /// Returns `.infinity` for mismatched dimensions rather than trapping — a corrupt
    /// descriptor should exclude itself from clustering, not crash a library scan.
    public func distance(to other: Embedding) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return .infinity }
        var sum: Double = 0
        for i in values.indices {
            let d = Double(values[i]) - Double(other.values[i])
            sum += d * d
        }
        return sum
    }
}

/// Quality gate applied before clustering.
///
/// Filtering aggressively here is the single highest-leverage tuning knob: one blurry
/// three-quarter-profile face can chain two distinct people into one cluster, and that
/// error is unrecoverable downstream.
public struct QualityGate: Sendable {
    public var minDetectionConfidence: Float
    public var minCaptureQuality: Float
    public var minRelativeSize: Double
    public var maxAbsYawDegrees: Double

    public init(
        minDetectionConfidence: Float = 0.7,
        minCaptureQuality: Float = 0.4,
        minRelativeSize: Double = 0.045,
        maxAbsYawDegrees: Double = 35
    ) {
        self.minDetectionConfidence = minDetectionConfidence
        self.minCaptureQuality = minCaptureQuality
        self.minRelativeSize = minRelativeSize
        self.maxAbsYawDegrees = maxAbsYawDegrees
    }

    public static let `default` = QualityGate()

    public func admits(_ face: FaceDescriptor) -> Bool {
        if face.detectionConfidence < minDetectionConfidence { return false }
        // A missing quality score is not treated as a failure: the capture-quality
        // request is a separate Vision call that may legitimately not have run.
        if let q = face.captureQuality, q < minCaptureQuality { return false }
        if face.relativeSize < minRelativeSize { return false }
        if abs(face.yawDegrees) > maxAbsYawDegrees { return false }
        return true
    }
}
