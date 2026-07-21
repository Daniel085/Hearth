#if canImport(Vision)
import Testing
import Foundation
import Vision
import CoreGraphics
@testable import FaceClustering

/// Verifies the bridge from Vision's feature print to our `[Float]` `Embedding`.
///
/// The clusterer compares embeddings with plain Euclidean distance. Vision offers its own
/// `distance(to:)`. These tests confirm the two agree — if they don't, every threshold
/// calibrated with one metric would be meaningless under the other, and the failure would
/// be silent.

/// Builds a solid-colour image so feature prints are deterministic and distinct.
private func solidImage(
    red: CGFloat, green: CGFloat, blue: CGFloat, size: Int = 128
) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // A contrasting band gives the descriptor real structure to encode.
    ctx.setFillColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 3))
    return ctx.makeImage()
}

@available(iOS 18.0, macOS 15.0, *)
private func featurePrint(for image: CGImage) async throws -> FeaturePrintObservation {
    try await GenerateImageFeaturePrintRequest().perform(on: image)
}

@Test("Vision feature print decodes into a non-empty embedding")
@available(iOS 18.0, macOS 15.0, *)
func featurePrintDecodes() async throws {
    guard let image = solidImage(red: 0.9, green: 0.2, blue: 0.2) else {
        Issue.record("Could not construct test image")
        return
    }
    let print = try await featurePrint(for: image)
    let embedding = try #require(Embedding(featurePrint: print))

    #expect(!embedding.values.isEmpty)
    #expect(embedding.values.count == print.elementCount)
    // A descriptor of all zeros would mean we misread the buffer.
    #expect(embedding.values.contains { $0 != 0 })
}

/// Vision's `distance(to:)` is **squared** Euclidean — established by measuring it
/// against decoded vectors, exact to six decimals over every pair. This test pins that
/// down: if a future Vision revision changes the metric, thresholds calibrated against
/// the old one would silently become wrong, and this is what would catch it.
@Test("Our metric matches Vision's distance (squared Euclidean)")
@available(iOS 18.0, macOS 15.0, *)
func visionDistanceMatchesOurMetric() async throws {
    guard let a = solidImage(red: 0.9, green: 0.1, blue: 0.1),
          let b = solidImage(red: 0.1, green: 0.2, blue: 0.9),
          let c = solidImage(red: 0.15, green: 0.25, blue: 0.85) else {
        Issue.record("Could not construct test images")
        return
    }

    let pa = try await featurePrint(for: a)
    let pb = try await featurePrint(for: b)
    let pc = try await featurePrint(for: c)

    let ea = try #require(Embedding(featurePrint: pa))
    let eb = try #require(Embedding(featurePrint: pb))
    let ec = try #require(Embedding(featurePrint: pc))

    // Compare against Vision's metric on several pairs.
    for (p1, p2, e1, e2) in [(pa, pb, ea, eb), (pa, pc, ea, ec), (pb, pc, eb, ec)] {
        let visionDistance = try p1.distance(to: p2)
        let ourDistance = e1.distance(to: e2)
        #expect(
            abs(visionDistance - ourDistance) < 0.01,
            "Vision reported \(visionDistance), we computed \(ourDistance)"
        )
    }
}

@Test("Identical images produce near-zero distance")
@available(iOS 18.0, macOS 15.0, *)
func identicalImagesAreClose() async throws {
    guard let image = solidImage(red: 0.4, green: 0.6, blue: 0.3) else {
        Issue.record("Could not construct test image")
        return
    }
    let p1 = try await featurePrint(for: image)
    let p2 = try await featurePrint(for: image)

    let e1 = try #require(Embedding(featurePrint: p1))
    let e2 = try #require(Embedding(featurePrint: p2))

    #expect(e1.distance(to: e2) < 0.001)
}

@Test("Similar images are closer than dissimilar ones")
@available(iOS 18.0, macOS 15.0, *)
func relativeOrderingHolds() async throws {
    guard let red = solidImage(red: 0.9, green: 0.1, blue: 0.1),
          let nearRed = solidImage(red: 0.85, green: 0.15, blue: 0.12),
          let blue = solidImage(red: 0.1, green: 0.1, blue: 0.9) else {
        Issue.record("Could not construct test images")
        return
    }

    let eRed = try #require(Embedding(featurePrint: try await featurePrint(for: red)))
    let eNear = try #require(Embedding(featurePrint: try await featurePrint(for: nearRed)))
    let eBlue = try #require(Embedding(featurePrint: try await featurePrint(for: blue)))

    #expect(eRed.distance(to: eNear) < eRed.distance(to: eBlue))
}
#endif
