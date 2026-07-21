#if canImport(Vision)
import Vision
import CoreGraphics
import Foundation

/// Turns images into `FaceDescriptor`s using Vision.
///
/// ## The central caveat
///
/// Vision has **no face-identity embedding API**. There is no `VNFaceprint`, and no
/// request that produces a descriptor trained to distinguish *who* a face belongs to.
/// (Verified against the iOS 26.5 SDK: the Vision module exposes only
/// `DetectFaceRectanglesRequest`, `DetectFaceLandmarksRequest`, and
/// `DetectFaceCaptureQualityRequest` for faces.) The Photos app's own "People" album is
/// built on a private framework that PhotoKit does not expose.
///
/// This extractor therefore detects faces, crops them, and runs
/// `GenerateImageFeaturePrintRequest` over each crop. That request produces a
/// *general-purpose image similarity* descriptor — it was trained to tell a beach from a
/// bicycle, not Sarah from Joe. Two crops of the same person in similar lighting will
/// often score as similar, but so will two different people photographed against the
/// same wall.
///
/// **This is the assumption the prototype exists to test.** Run
/// `ClusteringEvaluator` against a labelled sample from a real library before any
/// further work depends on it. If accuracy is inadequate, the fallback is a bundled
/// Core ML face-recognition model (e.g. a FaceNet/ArcFace conversion), which preserves
/// the on-device privacy guarantee but adds model weight and licensing questions.
@available(iOS 18.0, macOS 15.0, *)
public struct VisionFaceExtractor: Sendable {

    /// Padding around the detected face box, as a fraction of box size.
    ///
    /// **25% measurably beats 0% on a real library** — separation 0.588 vs 0.398, and it
    /// holds after normalising for distribution scale (sep/median 0.556 vs 0.469,
    /// sep/spread 0.753 vs 0.664), so it is not an artifact of the whole distribution
    /// stretching. See `docs/vision-findings.md` §4c.
    ///
    /// This contradicts the prediction drawn from published benchmarks, which found
    /// general-purpose embeddings improving with looser crops because they read context
    /// rather than facial geometry. The likely reconciliation: those studies compared
    /// whole-image crops at 112px vs 250px — a far larger context change than 25% padding
    /// around a face box. At this scale the extra pixels are hair, jaw and head shape,
    /// which are genuine identity signal, not background.
    ///
    /// Values well above 0.25 are untested and would start pulling in real background.
    public var cropPadding: Double

    public init(cropPadding: Double = 0.25) {
        self.cropPadding = cropPadding
    }

    public func extractFaces(
        from image: CGImage,
        assetIdentifier: String,
        captureDate: Date?
    ) async throws -> [FaceDescriptor] {

        let faceRequest = DetectFaceRectanglesRequest()
        let observations = try await faceRequest.perform(on: image)
        guard !observations.isEmpty else { return [] }

        let qualityRequest = DetectFaceCaptureQualityRequest()
        let qualityByUUID: [UUID: Float] = await {
            do {
                let scored = try await qualityRequest.perform(on: image)
                return Dictionary(
                    uniqueKeysWithValues: scored.compactMap { obs in
                        obs.captureQuality.map { (obs.uuid, $0.score) }
                    }
                )
            } catch {
                // Quality scoring is an optimisation, not a requirement. Losing it means
                // a weaker gate, not a failed scan.
                return [:]
            }
        }()

        let imageSize = CGSize(width: image.width, height: image.height)
        let minDimension = Double(min(image.width, image.height))
        var descriptors: [FaceDescriptor] = []

        for observation in observations {
            let faceRect = observation.boundingBox.toImageCoordinates(
                imageSize, origin: .upperLeft
            )

            guard let cropRect = paddedRect(faceRect, in: imageSize),
                  let crop = image.cropping(to: cropRect) else { continue }

            let printRequest = GenerateImageFeaturePrintRequest()
            guard let featurePrint = try? await printRequest.perform(on: crop),
                  let embedding = Embedding(featurePrint: featurePrint) else { continue }

            descriptors.append(
                FaceDescriptor(
                    assetIdentifier: assetIdentifier,
                    captureDate: captureDate,
                    detectionConfidence: observation.confidence,
                    captureQuality: qualityByUUID[observation.uuid],
                    relativeSize: Double(faceRect.width) / minDimension,
                    yawDegrees: observation.yaw.converted(to: .degrees).value,
                    rollDegrees: observation.roll.converted(to: .degrees).value,
                    embedding: embedding
                )
            )
        }

        return descriptors
    }

    /// Expands the face box by `cropPadding`, clamped to the image bounds.
    /// Returns nil if the result is degenerate.
    private func paddedRect(_ rect: CGRect, in size: CGSize) -> CGRect? {
        let dx = rect.width * cropPadding
        let dy = rect.height * cropPadding
        let padded = rect.insetBy(dx: -dx, dy: -dy)
        let clamped = padded.intersection(CGRect(origin: .zero, size: size)).integral
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension Embedding {
    /// Bridges Vision's feature print into our testable representation.
    ///
    /// `FeaturePrintObservation` exposes its raw buffer via `data`, along with
    /// `elementCount` and `elementType`, so the vector can be read out directly and the
    /// clusterer can run on the same `[Float]` representation the tests use.
    ///
    /// Vision emits either `Float` or `Double` elements depending on revision; both are
    /// normalised to `[Float]` here. Our `distance` is plain Euclidean, matching what
    /// `FeaturePrintObservation.distance(to:)` computes — verified by
    /// `visionDistanceMatchesEuclidean` in the test suite.
    init?(featurePrint: FeaturePrintObservation) {
        let data = featurePrint.data
        let count = featurePrint.elementCount
        guard count > 0 else { return nil }

        switch featurePrint.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return nil }
            let values = data.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: Float.self),
                    count: count
                ))
            }
            self.init(values: values)

        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return nil }
            let values = data.withUnsafeBytes { raw in
                UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: Double.self),
                    count: count
                ).map { Float($0) }
            }
            self.init(values: values)

        @unknown default:
            // A future element type we can't interpret. Excluding the face is correct;
            // guessing at the layout would silently corrupt every distance it touches.
            return nil
        }
    }
}
#endif
