# Vision Prototype — Findings

**Status:** Prototype builds and unit-tests pass; **not yet validated against a real photo library**
**Date:** 2026-07-21
**Code:** [`prototypes/FaceClustering`](../prototypes/FaceClustering)
**Verified against:** iOS 26.5 SDK, Swift 6.3.3

---

## 1. The headline finding: Vision has no face-identity API

The data model doc originally assumed a `VNFaceprint` type existed and could be stored
per face for identity comparison. **That was wrong.** Checked directly against the
iOS 26.5 SDK's Vision interface — both the Swift module and the Objective-C headers —
the string "Faceprint" does not appear anywhere. The face-related API surface is
exactly:

- `DetectFaceRectanglesRequest` — where faces are
- `DetectFaceLandmarksRequest` — eyes, nose, mouth positions
- `DetectFaceCaptureQualityRequest` — a 0–1 quality score
- `FaceObservation` — bounding box, roll/yaw/pitch, confidence

None of these answer *whose* face it is. Additionally, the Photos app's own "People"
album — which clearly does solve this problem — is built on a private framework that
PhotoKit does not expose. **We cannot piggyback on the work iOS has already done.**

This is load-bearing for the product, so it's worth stating plainly: the central
technical assumption in the README ("Analyzes your photo library using iOS Vision
framework to identify people you spend time with") is not directly supported by the
framework.

## 2. The workaround, and why it may not hold

`GenerateImageFeaturePrintRequest` does exist, produces an embedding, and offers
`distance(to:)`. The prototype detects faces, crops each one with 25% padding, and runs
a feature print over the crop.

**The catch:** this request produces a *general-purpose image similarity* descriptor.
It was trained to distinguish a beach from a bicycle — not Sarah from Joe. Two photos of
the same person in similar lighting will often come out close, but so will two different
people photographed against the same wall. The descriptor may be responding to
background, lighting, and colour as much as to facial identity.

**Whether this is good enough is an open empirical question, and it is the one thing
this prototype cannot answer on its own.** It needs to be run against a real,
hand-labelled photo library.

### If it isn't good enough

The fallback is bundling a purpose-built face-recognition model and running it over the
crops instead — same on-device guarantee, nothing leaves the phone. The clustering,
quality-gating, and evaluation code all sit behind a `distance`-shaped abstraction, so
**swapping the embedding source doesn't require rewriting any of it.**

But the swap is far narrower than "FaceNet, ArcFace, or similar" implied. See
[core-ml-comparison.md](./core-ml-comparison.md) — **most high-accuracy face models cannot
legally ship in a commercial app**, because the restriction lives on the pretrained
weights and their training data, not the code.

## 3. What was built

Four components, all compiling against the real SDK:

| File | Role |
|---|---|
| `FaceDescriptor.swift` | Platform-free face representation + quality gate |
| `FaceClusterer.swift` | Agglomerative clustering, average linkage |
| `VisionFaceExtractor.swift` | Vision detection → crop → feature print |
| `ClusteringEvaluator.swift` | Precision/recall scoring + threshold sweep |

17 unit tests pass, covering separation, merging, chain resistance, quality gating,
burst collapsing, labelling priority, evaluator correctness, and the Vision bridge.
The clustering tests run on synthetic embeddings — **they prove the algorithm is
correct, not that the embeddings can distinguish real faces.**

### Design decisions worth knowing about

**Average linkage, not single linkage.** The naive "merge if any two faces are close"
approach suffers from chaining: A is near B, B near C, C near D, and suddenly A and D
are one cluster despite being far apart. In practice one ambiguous photo welds two
different people together permanently. Average linkage requires groups to be close *on
the whole*. It occasionally splits one person into two clusters instead — and that
trade is deliberate, because **a split person is a mild annoyance the user can merge,
while two people merged into one is a wrong relationship the user can't easily undo.**
There's a regression test for this.

**Quality gating before clustering.** Faces are rejected if small (<4.5% of the image),
low quality (<0.4), or turned more than 35° away. This is the highest-leverage tuning
knob available: a single blurry profile shot is exactly the kind of bridge that chains
two people together.

**Ranking by recurrence, not photo count.** Photo volume is a bad proxy for
relationship strength — you photograph a wedding you attended once far more than the
sibling you see weekly. The labelling priority weights *distinct days* and *time span*
above raw count, so a person seen four times across a year outranks one photographed ten
times at a single event. Tested.

**Distinct photos, not distinct faces.** Burst shots collapse — twelve faces from one
burst counts as one photo of evidence.

## 4. What this means for onboarding

Since clusters come back unlabelled and there's no way to import the Photos People
album, **the user must name people manually.** The prototype caps this at the 20
highest-priority clusters. That is still 20 questions before the app does anything
useful, which is a real onboarding cost and probably the biggest UX risk in the product.

Worth considering: seed the labelling with Contacts entries that have photos, so some
clusters arrive pre-guessed rather than blank.

## 4a. The distance metric — measured, not assumed

Two corrections to earlier assumptions in this document, both found by writing a test
against real Vision output rather than trusting the API's shape:

**`FeaturePrintObservation` does expose its vector.** It has `.data`, `.elementCount`,
and `.elementType`. The earlier claim that it was opaque was wrong, and
`VisionEmbeddingStore` (built to work around that) has been deleted as unnecessary. For
revision 2 the vector is **768 floats, L2-normalised** (norm ≈ 0.9997).

**Vision's `distance(to:)` is _squared_ Euclidean, not Euclidean.** The first version of
this code took a square root and a test comparing it to Vision's own metric failed by
0.23 — a large, consistent gap. Probing across six image pairs showed the squared value
matching Vision exactly to six decimal places.

This one is worth dwelling on because of *how* it fails. Using the wrong metric doesn't
crash or produce obvious garbage: clustering still runs, still produces plausible-looking
groups, just with a merge boundary that's wrong by a nonlinear factor. Every threshold
calibrated afterwards would be quietly meaningless. It's exactly the class of bug that
survives to production because nothing visibly breaks.

Practical consequences:
- The merge threshold is in **squared** units, bounded in **[0, 4]** (0 identical,
  2 orthogonal). Because vectors are normalised, this equals 2 × cosine distance.
- The threshold sweep now spans 0.05–1.50; above ~1.5 essentially everything merges.
- `visionDistanceMatchesOurMetric` pins the metric down, so a future Vision revision
  that changes it fails a test instead of silently corrupting results.

## 4b. First real-device scan — 2026-07-21

Run against a real iPhone library. Result:

- **No contaminated groups.** No cluster mixed two different people. This was the stated
  kill criterion in §6, and it passed.
- **Heavy fragmentation on one subject.** A baby appeared across many separate groups,
  and the merge threshold had to be pushed to **1.0+** before most of them combined.

Fragmentation was always the tolerable failure (§3) — users can merge groups; they cannot
un-merge two people convincingly. So this is not a veto. But 1.0 on a [0, 4] scale where
2.0 means orthogonal is high enough to warrant explanation, and there are two candidates
with opposite consequences:

1. **The descriptor is weak at faces.** Same-person and different-person distances
   overlap, no threshold truly works, and the fallback in §2 is required.
2. **The descriptor is fine and the face genuinely changed.** A baby's face changes more
   in six months than an adult's in a decade. A large distance would then be *correct* —
   the descriptor reporting real change, not failing.

These are indistinguishable from the cluster view alone, so guessing between them would
be exactly the kind of unfalsifiable impression this prototype exists to avoid.

### The diagnostics screen

Added to settle it, using a trick that needs no manual labelling: **two faces in the same
photo are necessarily different people.** That yields free ground truth for what
"different person" scores in this library.

`separation = median(same-photo pairs) − p10(all pairs)`, comparing the low end of the
overall distribution (mostly same-person) against known-different pairs. Wide separation
means explanation 2; near-zero means explanation 1.

**A bug found while testing this:** the first version computed `separation` from as few as
two same-photo pairs, where the "median" is just an arbitrary order statistic. On a
deliberately blind fixture it reported separation of 1.88 — a confident-looking number
manufactured from noise. It now withholds a verdict below 8 pairs and says why. The unit
test that caught it (`blindDescriptorDoesNotSeparate`) is in the suite.

## 4c. Diagnostics results — and a prediction that failed

Two scans of the same library, differing only in crop padding.

| Measure | **25% padding** | **0% padding** |
|---|---|---|
| **Separation** | **0.588** | 0.398 |
| Pairs compared | 21,945 | 21,736 |
| Same-photo (known-different) pairs | 63 | 63 |
| Closest pair | 0.012 | 0.016 |
| p10 / median / p90 | 0.540 / 1.057 / 1.321 | 0.487 / 0.848 / 1.086 |
| Furthest | 1.697 | 1.431 |

**Verdict: the descriptor is separating faces**, comfortably, at both settings. Both are
above the 0.30 "working" band on a large sample with ample ground truth. The §2 worry —
that `FeaturePrint` might be blind to facial identity — is not what is happening here.

That resolves §4b in favour of explanation 2: **the baby's face genuinely changed.** The
very wide same-person band (closest pair 0.012, but p10 already 0.540) is the signature of
real change over months, not a broken descriptor.

### The failed prediction

§1 of [core-ml-comparison.md](./core-ml-comparison.md) predicted that **tighter** crops
would separate better, reasoning from benchmarks where general-purpose embeddings improve
with looser crops because they read background rather than facial geometry. The opposite
happened: 25% padding beat 0% by ~48%.

The result survives the obvious objection. Every statistic rose between runs, so
separation was re-checked normalised against the distribution's own scale:

| Normalised measure | 25% | 0% |
|---|---|---|
| separation ÷ median | **0.556** | 0.469 |
| separation ÷ p90 | **0.445** | 0.366 |
| separation ÷ (p90 − p10) | **0.753** | 0.664 |

25% wins on all three, so this is genuinely better discrimination rather than an artifact
of the distribution stretching.

**Likely reconciliation:** the published studies compared *whole-image* crops at 112px vs
250px — a far larger context change than 25% padding around a face box. At this scale the
extra pixels are hair, jaw and head shape, which are real identity signal, not background.
The benchmark finding may simply not transfer to small paddings.

**Lesson worth keeping:** the published-benchmark reasoning was plausible, specific, and
wrong for this library. Measure on the target data before acting on transferred results.
The slider now goes to 75% so larger paddings can be tested rather than assumed —
though at some point padding must start pulling in real background.

### A caveat on the suggested threshold

The first version of this screen derived a "suggested threshold" as the midpoint between
p10 and the different-person median — which gave **0.69** here, well below the **1.0+**
actually needed to group the baby. A user following that suggestion would fragment the
very person they were trying to group.

The midpoint is a heuristic over the whole distribution; it has no knowledge of how far a
*particular* changing face drifts. It has been demoted to "midpoint estimate" and replaced
as the headline number by a **measured safe ceiling**: the highest threshold at which no
known-different (same-photo) pair merges. A **contamination-by-threshold table** now shows
where wrong merges begin, so the ceiling is visible rather than asserted.

This matters beyond diagnostics — it is how the shipping default threshold should be
chosen: per-library, from that library's own ground truth, not from a constant.

## 4d. Clustering performance, and a silent data-loss bug

The threshold slider was unusable — laggy and unresponsive while dragging. Two distinct
causes, both fixed.

### The algorithm was O(n⁴)

The original implementation recomputed average linkage between *every pair of groups* on
*every merge*. Measured at **~364ms for 210 faces** (21,945 pairs) in release on a Mac —
worse on a phone, and the slider fires one of these per step.

Replaced with the standard **Lance-Williams** formulation, which maintains a live
group-distance matrix and updates it in place after each merge:

```
d(i∪j, k) = (|i|·d(i,k) + |j|·d(j,k)) / (|i| + |j|)
```

Each merge is now O(n) to update instead of O(n³) to recompute. The distance matrix also
moved from `[UUID: [UUID: Double]]` to a flat `[Double]`, removing two dictionary hashes
per lookup in the hottest loop.

**364ms → 7ms, a ~50× speedup.** This is the same algorithm, not an approximation —
verified by differential-testing the new implementation against the original across 30
configurations (6 face sets × 5 thresholds): **identical cluster membership every time.**

### The bug the verification found

The equivalence check failed at first, which turned out to be a **pre-existing bug**, not
a regression.

`surfaced` returned `prefix(maxClustersToSurface)` and `belowThreshold` returned only
clusters with too few assets. Clusters that were numerous enough to surface but ranked
past position 20 landed in **neither list and vanished from the result entirely.** In one
test 40 of 60 faces disappeared.

Silent data loss — nothing errored, no exception, the counts just quietly failed to add
up. It would have been invisible in the UI, since the screen only ever shows the top 20.
Now fixed: overflow clusters go into `belowThreshold`. Two regression tests cover it —
one asserting every input face appears exactly once in the output, one asserting
determinism across runs.

### The main-thread block

Even at 7ms, re-clustering ran **synchronously on the main actor** — the same thread
drawing the slider. Now it runs in a detached task, with in-flight work cancelled when a
newer threshold arrives, since mid-drag values are throwaway.

## 5. Known limitations

1. **Still O(n²) memory.** The clusterer holds a full pairwise distance matrix. At a few
   hundred faces that is trivial; a 30,000-photo library would need blocking (cluster
   within time windows, then merge across) or a nearest-neighbour index. The O(n⁴) *time*
   problem is fixed (§4d); memory is not.
2. **The default merge threshold is a guess.** It has to be read off real labelled data
   via `sweepThresholds`; the constant in the code is a conservative placeholder.
3. **Untested on real faces.** The Vision bridge is verified against synthetic images,
   which proves the plumbing and the metric — not that feature prints can tell two
   people apart. That remains §2's open question and needs the device.

## 6. Next step — and it needs a device

The prototype's purpose is to produce a number that can veto the approach. The embedding
bridge is now real (§4a), so what remains is:

1. Scan a bounded sample of the real library via PhotoKit — a few hundred photos.
2. Hand-label the resulting clusters with real identities.
3. Run `ClusteringEvaluator.sweepThresholds` and read off the best merge threshold.

This requires a physical device: the simulator's photo library is a handful of stock
images with no recurring people, so it cannot test clustering at all.

**Success criteria, decided before seeing the data:** contaminated clusters at or near
zero, precision above ~0.95, recall above ~0.70. Precision matters far more than recall
for the reason given in §3 — merging two people is the unacceptable failure.

If those numbers can't be hit with feature prints, move to a bundled Core ML face model
before building any UI on top of this.
