# Vision FeaturePrint vs. a bundled Core ML face model

**Date:** 2026-07-21
**Status:** Research summary. Not legal advice — §3 needs a lawyer before shipping.

Answers: how does what we have now compare to a dedicated face-recognition model, and
what would swapping actually cost?

---

## 1. The accuracy gap is large and well-attested

Face-verification accuracy on LFW, at a strict operating point
(TMR@FMR=0.01%):

| Approach | Accuracy |
|---|---|
| Dedicated face models (ArcFace, AdaFace, EdgeFace) | **98.9 – 99.8%** |
| OpenCLIP-H-14 (general image embedding) | **64.97%** |
| CLIP-L-14-336 (general image embedding) | **63.49%** |

The cleanest evidence isolates *why*, holding architecture fixed. FRoundation (CVIU 2025)
took the same DINOv2 ViT-S backbone and measured it two ways: **78.73% frozen, 98.38%
after face-specific training.** A ~20-point swing attributable purely to training
objective. Architecture isn't the problem; what the model was trained to care about is.

**Directly relevant to our baby-fragmentation puzzle (§4b):** general embeddings get
*better* with looser crops (OpenCLIP 64.97% → 81.73% going from 112px to 250px) while
ArcFace *collapses* (98.86% → 32.88%). Dedicated models read facial geometry; general
embeddings read context — hair, clothing, background, lighting.

Our extractor pads crops by 25%, which suggested it might be feeding exactly the
contextual signal a general descriptor latches onto.

> **This prediction was tested and failed.** On the real library, 25% padding separated
> *better* than 0% (0.588 vs 0.398, and it holds after normalising for scale). See
> [vision-findings.md](./vision-findings.md) §4c. The benchmarks above compared
> whole-image crops at very different resolutions; at 25% padding around a face box the
> extra pixels are hair and jaw — real identity signal, not background. **Treat the
> transferred benchmark reasoning below with corresponding caution.**

**Caveat that matters:** no published benchmark measures Apple's `FeaturePrint` on faces
specifically. The above is strong proxy evidence, not a direct measurement of what we're
using. The device scan remains the only thing that measures *this* library.

**A second caveat about our own diagnostics.** The separation metric uses same-photo pairs
as "definitely different people" — but those pairs *share a background*. For a
context-sensitive descriptor that's the hardest possible different-person case, which
means **the diagnostics screen may understate the problem.** A poor separation reading is
conclusive; a good one is weaker evidence than it appears.

**Also worth knowing:** Apple changed `FeaturePrint` from 2048-D unnormalised (Revision 1)
to 768-D L2-normalised (Revision 2). Our measured §4a values match Revision 2. Any
threshold we calibrate is **revision-specific and can be invalidated by an OS update** —
an argument for pinning the revision explicitly and re-validating on major iOS releases.

## 2. Licensing eliminates most of the field

The critical finding, and the reason "just swap in ArcFace" isn't available.

**Code licenses (MIT/Apache) do not cover the weights.** Restrictions propagate from the
training data — MS-Celeb-1M, Glint360K, WebFace42M, VGGFace2 are research-only.

| Model | LFW | Weights license | Shippable? |
|---|---|---|---|
| InsightFace buffalo_l / antelopev2 | 99.83 | Non-commercial, explicit | **No** |
| EdgeFace (all variants) | 99.57–99.83 | CC-BY-NC-SA-4.0 | **No** |
| AdaFace, FaceNet, GhostFaceNets | 99.1–99.8 | Unspecified + tainted data | **No** |
| FaceLiVTv2 | 99.63–99.80 | Glint360K, LICENSE "Unknown" | **No** |
| **SFace** (OpenCV Zoo) | ~99.4 | **Apache-2.0 on weights** | **Probably** |
| **dlib face rec ResNet** | 99.38 | **Public domain** | **Probably** |

InsightFace states it plainly: the data and *the models trained with it* are "available
for non-commercial research purposes only."

**Residual risk on both viable options.** SFace's upstream repo has no LICENSE and was
trained on CASIA-WebFace / VGGFace2 / MS-Celeb-1M; OpenCV relicensed Apache-2.0
downstream regardless. dlib's weights are ~50% VGG Face (CC BY-NC). Whether dataset
restrictions propagate to trained weights is **genuinely unsettled law** — this needs a
lawyer, not an engineering judgement. (Note: dlib's 5-point landmark predictor is clean;
the 68-point one is explicitly non-commercial.)

**A licensing path exists.** InsightFace now sells commercial licenses via
`recognition-oss-pack@insightface.ai`. Given buffalo_l at 99.83% and a 16MB packaging
option, sending that email is probably worth doing before engineering around the
constraint.

## 3. The legal issue that outweighs the technical one

**"It's all on-device" is not currently a winning BIPA defense.**

Apple won *Barnett* (2022) on that theory for Face ID. But in the Apple **Photos** case,
S.D. Ill. certified a **~6.5 million member** Illinois class in June 2026 over on-device
faceprints, with reported exposure of **$6.5B–$32.5B**.

The distinguishing fact maps onto Hearth almost exactly: Photos clusters faces
**automatically, by default**, generating faceprints of **third parties in the photos who
are not users and never consented.** No consent screen shown to *our* user can cure that —
the people in the photos aren't the ones agreeing.

Google geofences Face Grouping out of Illinois and Texas. Apple didn't, and is the one in
court.

Concrete mitigations, all cheap if designed in now and expensive to retrofit:
- Face scanning **opt-in and off by default** (not the current design — the scan screen is
  step one of onboarding)
- §15(b)-style written consent before first scan
- Published retention and destruction policy, with deletion that actually deletes
- A deliberate decision on geofencing Illinois

**Apple's App Review posture is separately permissive.** On-device data isn't "collected"
by Apple's definition, so the privacy label can legitimately say "Data Not Collected."
But guideline **5.1.2(vi)** hard-walls face-derived data from analytics and advertising —
and the optional iCloud sync in the README would flip the label to Sensitive Info.

## 4. Integration cost

- **Latency is a non-issue.** MobileFaceNet-class at 112×112 measures **0.77ms** on
  iPhone 15 Pro / iOS 26 via Core ML; Apple's own Photos embedding runs <4ms on ANE.
  Detection, alignment and image I/O will dominate scan time either way.
- **coremltools 9.0 removed ONNX support** (dropped in 6.0; `onnx-coreml` archived).
  SFace ships *only* as ONNX, so it needs `onnx2torch` → `torch.jit.trace` → convert, with
  numerics verified after.
- **Alignment is the real integration risk.** ArcFace's canonical 5-point reference comes
  from MTCNN *eye centers*; Vision gives *pupils*, which move with gaze. No published
  measurement of the accuracy cost. Mitigation: enrol and query with the same detector so
  the bias cancels.
- **SFace ships calibrated thresholds** (cosine ≥0.363 / L2 ≤1.128), which directly fills
  the "threshold is a guess" gap in §5. It's 128-D, so the [0,4] squared-distance bounds
  carry over unchanged.

## 5. Reading

The technical case for a dedicated model is strong — roughly 99% vs. ~65% on a
comparable proxy task, with a mechanism (context vs. geometry) that explains the
fragmentation actually observed.

But the decision is no longer primarily technical:

1. **Legal review gates the good models.** The high-accuracy field is unshippable without
   a purchased license. The free options (SFace, dlib) carry unsettled residual risk.
2. **BIPA exposure is the larger question** and applies *regardless of which embedding we
   use* — it attaches to generating faceprints of non-consenting third parties, which
   Hearth does today with Vision.

Point 2 deserves emphasis: it is not a reason to prefer one model over the other. It is a
product-design question about defaults, consent, and geography that is live right now.
