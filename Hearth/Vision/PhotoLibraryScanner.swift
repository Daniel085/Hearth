import Photos
import Vision
import CoreGraphics
import Foundation
import UIKit

/// Walks the photo library, extracts faces, and clusters them.
///
/// Deliberately bounded: `sampleLimit` caps how many photos a scan touches. The first
/// job of this code is to produce a validation number from a few hundred photos, not to
/// process a 30,000-photo library — the clusterer is O(n²) and would not survive that
/// (see `docs/vision-findings.md` §5).
@MainActor
final class PhotoLibraryScanner: ObservableObject {

    enum State: Equatable {
        case idle
        case requestingPermission
        case denied
        case scanning(processed: Int, total: Int, facesFound: Int)
        case clustering
        case finished(ScanSummary)
        case failed(String)
    }

    /// Distribution of pairwise embedding distances, used to tell a weak descriptor
    /// apart from a face that genuinely changed. See `distanceStatistics()`.
    struct DistanceStatistics: Equatable {
        let pairCount: Int
        let minimum: Double
        let p10: Double
        let median: Double
        let p90: Double
        let maximum: Double

        /// Pairs of faces found in the *same photo* — necessarily different people.
        let knownDifferentPersonPairs: Int
        let knownDifferentPersonMedian: Double?

        /// Minimum same-photo pairs before `separation` is trustworthy.
        ///
        /// With only a handful, the "median" is really an arbitrary order statistic and
        /// the resulting number is noise dressed as a measurement. 8 is a judgement call,
        /// not a derived constant — but reporting nothing beats reporting a figure that
        /// looks authoritative and isn't.
        static let minimumPairsForConfidence = 8

        /// How much room there is between "same person" and "different person".
        ///
        /// Compares the low end of the overall distribution (mostly same-person pairs)
        /// against same-photo pairs (definitely different people). A large gap means a
        /// usable threshold exists; near zero means the descriptor cannot separate faces
        /// and no threshold will work.
        ///
        /// Nil when there aren't enough same-photo pairs to support the claim — see
        /// `hasEnoughGroundTruth`.
        var separation: Double? {
            guard hasEnoughGroundTruth, let diff = knownDifferentPersonMedian else { return nil }
            return diff - p10
        }

        var hasEnoughGroundTruth: Bool {
            knownDifferentPersonPairs >= Self.minimumPairsForConfidence
        }
    }

    struct ScanSummary: Equatable {
        let photosScanned: Int
        let facesDetected: Int
        let facesAdmitted: Int
        let clustersSurfaced: Int
        let clustersBelowThreshold: Int
        let duration: TimeInterval
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var clusters: [FaceCluster] = []

    /// Every descriptor from the last scan, retained so thresholds can be re-swept
    /// without re-scanning — a rescan is minutes, a re-cluster is milliseconds.
    private(set) var lastDescriptors: [FaceDescriptor] = []

    /// In-flight re-clustering, cancelled when a newer threshold arrives.
    private var reclusterTask: Task<Void, Never>?

    /// Crop padding used by the last scan. Exposed because it's an open experimental
    /// variable, not a tuned constant — see `VisionFaceExtractor.cropPadding`.
    @Published var cropPadding: Double = 0.25

    private var parameters = ClusteringParameters.default

    /// Photos are decoded at this size before Vision runs. Full-resolution decoding is
    /// both unnecessary for face detection and the main driver of scan time and thermals.
    private let targetSize = CGSize(width: 1024, height: 1024)

    func scan(sampleLimit: Int = 300) async {
        state = .requestingPermission

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            state = .denied
            return
        }

        let start = Date()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Only images; video frame extraction is a different pipeline.
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let assets = PHAsset.fetchAssets(with: options)
        let total = min(assets.count, sampleLimit)
        guard total > 0 else {
            state = .finished(ScanSummary(
                photosScanned: 0, facesDetected: 0, facesAdmitted: 0,
                clustersSurfaced: 0, clustersBelowThreshold: 0, duration: 0
            ))
            return
        }

        state = .scanning(processed: 0, total: total, facesFound: 0)

        let extractor = VisionFaceExtractor(cropPadding: cropPadding)
        var descriptors: [FaceDescriptor] = []
        var processed = 0

        for index in 0..<total {
            if Task.isCancelled { break }
            let asset = assets.object(at: index)

            if let image = await loadImage(for: asset) {
                do {
                    let faces = try await extractor.extractFaces(
                        from: image,
                        assetIdentifier: asset.localIdentifier,
                        captureDate: asset.creationDate
                    )
                    descriptors.append(contentsOf: faces)
                } catch {
                    // One unreadable photo shouldn't abort a scan of hundreds.
                    continue
                }
            }

            processed += 1
            // Update roughly every 5 photos; per-photo publishing dominates the runtime.
            if processed % 5 == 0 || processed == total {
                state = .scanning(processed: processed, total: total, facesFound: descriptors.count)
            }
        }

        state = .clustering
        lastDescriptors = descriptors

        // Pick the threshold from this library's own ground truth rather than a constant.
        //
        // Measured on a real library: the highest contamination-free threshold was 0.5,
        // while a face that changed over months needed 1.0+ — where 23% of
        // known-different pairs merge. No single hardcoded value can serve both, and a
        // constant tuned on one library will contaminate another.
        //
        // So cluster conservatively at the measured ceiling and let the user merge
        // fragments during labelling. A wrong merge is a false relationship they cannot
        // credibly undo; a fragment is one extra tap. See docs/vision-findings.md §4e.
        if let ceiling = safeThresholdCeiling() {
            parameters.mergeThreshold = ceiling
        }

        let result = FaceClusterer(parameters: parameters).cluster(descriptors)
        clusters = result.surfaced

        state = .finished(ScanSummary(
            photosScanned: processed,
            facesDetected: descriptors.count,
            facesAdmitted: descriptors.count - result.rejectedByQualityGate,
            clustersSurfaced: result.surfaced.count,
            clustersBelowThreshold: result.belowThreshold.count,
            duration: Date().timeIntervalSince(start)
        ))
    }

    /// What the two legacy "faces" collection constants actually return on this device.
    ///
    /// `PHAssetCollectionSubtypeAlbumSyncedFaces` and
    /// `PHCollectionListSubtypeSmartFolderFaces` look like they might expose the Photos
    /// People album. They don't — they're iPhoto/Aperture-via-iTunes leftovers. Header
    /// layout and Apple's own statements say so (see `docs/people-album-access.md`); this
    /// confirms it against the actual library rather than leaving it as inference.
    ///
    /// Reads collection titles and counts only — never photo content.
    static func probeLegacyFacesCollections() -> String {
        let synced = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumSyncedFaces, options: nil
        )
        let folders = PHCollectionList.fetchCollectionLists(
            with: .smartFolder, subtype: .smartFolderFaces, options: nil
        )

        var smartAlbumTitles: [String] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                if let title = collection.localizedTitle { smartAlbumTitles.append(title) }
            }

        let peopleLike = smartAlbumTitles.filter {
            let l = $0.lowercased()
            return l.contains("people") || l.contains("pet") || l.contains("face")
        }

        return """
        Synced-faces albums: \(synced.count)
        Smart-folder faces lists: \(folders.count)
        Smart albums visible: \(smartAlbumTitles.count)
        Titles suggesting people/pets/faces: \(peopleLike.isEmpty ? "none" : peopleLike.joined(separator: ", "))
        """
    }

    /// Sweeps merge thresholds and reports, at each one, how many same-photo pairs would
    /// be wrongly merged.
    ///
    /// Same-photo pairs are definitionally different people, so any threshold that merges
    /// one is producing a contaminated cluster. This gives a real ceiling on the usable
    /// threshold, measured rather than inferred from percentiles — which matters because
    /// the percentile-midpoint suggestion can land well below the value a genuinely
    /// changing face (a baby over months) actually needs.
    func contaminationSweep() -> [(threshold: Double, wrongMerges: Int, totalKnownPairs: Int)] {
        let admitted = lastDescriptors.filter { parameters.qualityGate.admits($0) }
        guard admitted.count >= 2 else { return [] }

        var knownDifferent: [Double] = []
        for i in 0..<admitted.count {
            for j in (i + 1)..<admitted.count
            where admitted[i].assetIdentifier == admitted[j].assetIdentifier {
                let d = admitted[i].embedding.distance(to: admitted[j].embedding)
                if d.isFinite { knownDifferent.append(d) }
            }
        }
        guard !knownDifferent.isEmpty else { return [] }

        return stride(from: 0.1, through: 1.6, by: 0.1).map { threshold in
            (threshold,
             knownDifferent.filter { $0 <= threshold }.count,
             knownDifferent.count)
        }
    }

    /// Highest threshold at which no known-different pair merges — the safe ceiling.
    /// Nil when even the tightest threshold contaminates, or there's no ground truth.
    func safeThresholdCeiling() -> Double? {
        let sweep = contaminationSweep()
        guard !sweep.isEmpty else { return nil }
        return sweep.last { $0.wrongMerges == 0 }?.threshold
    }

    /// Distance statistics over the descriptors from the last scan.
    ///
    /// Diagnoses *why* a high merge threshold was needed. Two very different causes look
    /// identical from the cluster view alone:
    ///
    /// - If the descriptor barely separates faces, distances between *all* face pairs
    ///   pile up in a narrow band — there is no threshold that works, and no amount of
    ///   tuning helps.
    /// - If the descriptor works but a face genuinely changed (a baby over months), most
    ///   pairs sit low and a subset sits high. The distribution is wide, not flat.
    ///
    /// The spread is the tell.
    func distanceStatistics() -> DistanceStatistics? {
        let admitted = lastDescriptors.filter { parameters.qualityGate.admits($0) }
        guard admitted.count >= 2 else { return nil }

        var distances: [Double] = []
        distances.reserveCapacity(admitted.count * (admitted.count - 1) / 2)
        for i in 0..<admitted.count {
            for j in (i + 1)..<admitted.count {
                let d = admitted[i].embedding.distance(to: admitted[j].embedding)
                if d.isFinite { distances.append(d) }
            }
        }
        guard !distances.isEmpty else { return nil }
        distances.sort()

        func percentile(_ p: Double) -> Double {
            let idx = Int(Double(distances.count - 1) * p)
            return distances[max(0, min(distances.count - 1, idx))]
        }

        // Same-photo pairs are necessarily different people (two faces, one frame), so
        // they give a free lower bound on what "different person" looks like — no
        // labelling required.
        var differentPersonDistances: [Double] = []
        for i in 0..<admitted.count {
            for j in (i + 1)..<admitted.count
            where admitted[i].assetIdentifier == admitted[j].assetIdentifier {
                let d = admitted[i].embedding.distance(to: admitted[j].embedding)
                if d.isFinite { differentPersonDistances.append(d) }
            }
        }

        return DistanceStatistics(
            pairCount: distances.count,
            minimum: distances.first ?? 0,
            p10: percentile(0.10),
            median: percentile(0.50),
            p90: percentile(0.90),
            maximum: distances.last ?? 0,
            knownDifferentPersonPairs: differentPersonDistances.count,
            knownDifferentPersonMedian: differentPersonDistances.isEmpty
                ? nil
                : differentPersonDistances.sorted()[differentPersonDistances.count / 2]
        )
    }

    /// Merges several clusters into one, for when a person was split across groups.
    ///
    /// Clustering runs at a conservative threshold (see `scan`), so a face that changed
    /// over time arrives as multiple groups. This is the user's correction, and it is
    /// the reason the conservative threshold is affordable: merging is one tap, whereas
    /// separating two people the algorithm wrongly fused is not something the UI can
    /// offer credibly.
    func mergeClusters(ids: Set<UUID>) {
        guard ids.count > 1 else { return }

        let merged = clusters.filter { ids.contains($0.id) }
        guard merged.count > 1 else { return }

        let combined = FaceCluster(faces: merged.flatMap(\.faces))
        var remaining = clusters.filter { !ids.contains($0.id) }

        // Keep the merged group where the strongest of its parts sat, so the list does
        // not reshuffle under the user's finger after a merge.
        let insertAt = clusters.firstIndex { ids.contains($0.id) } ?? 0
        remaining.insert(combined, at: min(insertAt, remaining.count))
        clusters = remaining
    }

    /// Re-clusters off the main actor, coalescing rapid changes.
    ///
    /// Dragging the threshold slider fires a change per step. Each one is a full
    /// re-clustering, so running them synchronously on the main actor froze the UI: the
    /// work blocked the same thread responsible for drawing the slider, and the calls
    /// queued up behind each other.
    ///
    /// Two fixes, both needed. The clustering moved off the main actor, and in-flight
    /// work is cancelled when a newer value arrives — mid-drag intermediate values are
    /// throwaway, so finishing them is wasted effort that delays the one the user
    /// actually lands on.
    func reclusterDebounced(mergeThreshold: Double) {
        reclusterTask?.cancel()
        parameters.mergeThreshold = mergeThreshold

        let descriptors = lastDescriptors
        let params = parameters

        reclusterTask = Task { [weak self] in
            // Brief pause so a fast drag doesn't spawn work per step.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .userInitiated) {
                FaceClusterer(parameters: params).cluster(descriptors)
            }.value

            guard !Task.isCancelled else { return }
            self?.clusters = result.surfaced
        }
    }

    /// Re-clusters synchronously. Prefer `reclusterDebounced` from UI.
    func recluster(mergeThreshold: Double) {
        parameters.mergeThreshold = mergeThreshold
        let result = FaceClusterer(parameters: parameters).cluster(lastDescriptors)
        clusters = result.surfaced
    }

    private func loadImage(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true   // iCloud-only originals are common
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isSynchronous = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize,
                contentMode: .aspectFit, options: options
            ) { image, info in
                // PhotoKit may call back more than once (degraded, then full). Resuming a
                // continuation twice is a crash, so guard it.
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                resumed = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}

/// Loads a cropped face thumbnail for review UI.
@MainActor
enum FaceThumbnailLoader {
    static func thumbnail(for face: FaceDescriptor, size: CGFloat = 200) async -> UIImage? {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [face.assetIdentifier], options: nil
        )
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: size * 3, height: size * 3),
                contentMode: .aspectFit, options: options
            ) { image, info in
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
