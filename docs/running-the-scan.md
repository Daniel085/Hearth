# Running the validation scan

**Date:** 2026-07-21

The app exists to answer one question before any more is built on top of it: **can Vision
feature prints tell one person's face from another's?** See
[vision-findings.md](./vision-findings.md) §2 for why this is in doubt.

This has to run on your iPhone. The simulator cannot answer it — verified, not assumed:
its stock library is six landscape photos, and running face detection over all six
returns **zero faces**. There is nothing there to cluster.

---

## Steps

1. Open `Hearth.xcodeproj` in Xcode.
2. Select the **Hearth** target → **Signing & Capabilities** → set **Team** to your
   Apple ID. (The project ships with an empty team so it isn't tied to one account.)
3. Plug in your iPhone, select it as the destination, and Run.
4. Grant photo access when prompted.
5. Set the sample size — **300 is a good first run**, roughly a few minutes — and tap
   **Start scan**.

## Reading the result

The results screen shows a scan summary and the groups it found, ranked by how often
someone recurs over time rather than by raw photo count.

**Tap into several groups.** The grid shows every face in that group, and this is the
measurement that matters:

- **Two different people inside one group** → contamination. This is the failure that
  kills the approach; it can't be fixed downstream and the user can't undo it.
- **The same person appearing as two separate groups** → fragmentation. Tolerable — a
  merge control fixes it.

Then drag the **merge threshold** slider. Re-grouping runs against descriptors already in
memory, so it's instant — no rescan. Lower splits people apart, higher merges them
together. Look for a value where groups stay clean.

## What counts as success

Decided before seeing any data, so the numbers aren't rationalised after the fact:

| Measure | Target |
|---|---|
| Groups containing two different people | 0, or very near it |
| Same person split across groups | ≤ ~1.5 groups per person on average |
| Useful threshold band | Wide enough that the exact value isn't critical |

Threshold values are **squared** Euclidean distance over L2-normalised vectors, bounded
in [0, 4] — see [vision-findings.md](./vision-findings.md) §4a.

**If contamination is common at every threshold**, feature prints aren't discriminating
faces and the fallback is a bundled Core ML face-recognition model. The clustering,
gating, and evaluation code all sit behind a `distance` abstraction, so that swap doesn't
require rewriting them.

## If you needed a high threshold

Open **Distance diagnostics** from the results screen. It measures whether the descriptor
can actually tell faces apart, using faces that appear in the same photo as a free
reference for "different people" — no labelling required.

Read the **Separation** figure:

| Separation | Meaning |
|---|---|
| > 0.30 | The descriptor is working. A high threshold reflects a face that genuinely changed. |
| 0.12 – 0.30 | Thin margin. Clustering will be fragile and threshold-sensitive. |
| < 0.12 | The descriptor isn't distinguishing faces. Move to a Core ML face model (§2). |

Those bands are interpretive starting points, not validated constants.

If it reports **"Not enough to judge"**, the scan didn't include enough photos containing
two or more faces. Scan a larger sample with more group shots — a subject photographed
alone every time provides no reference point.

## Crop padding — measured, not assumed

The scan screen has a **crop padding** slider. On this library, **25% clearly beats 0%**
(separation 0.588 vs 0.398), and the result holds after normalising for distribution
scale. A prediction from published benchmarks said tighter would be better; it was wrong
here — see [vision-findings.md](./vision-findings.md) §4c.

**25% is therefore the current default.** The slider now goes to 75% if you want to test
whether more helps further — that's untested, and at some point padding must start pulling
in background rather than face.

## Worth noting while you scan

- **Scan time per photo** is shown in the summary. Multiply by a realistic library size —
  if 300 photos takes 3 minutes, 10,000 takes an hour and a half, which is not a viable
  onboarding experience and would need background processing.
- **Whether the phone gets warm.** Sustained Vision work is thermally expensive.
- **How many faces fail the quality gate.** A large fraction rejected may mean the gate
  is too aggressive.

## Known limitation

The clusterer is O(n²) in faces — fine for a few hundred photos, unusable for a whole
library. Deliberately not optimised yet, since it may be replaced entirely depending on
what this scan shows. See [vision-findings.md](./vision-findings.md) §5.
