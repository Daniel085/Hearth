# Hearth — Core Data Model & Relationship Scoring

**Status:** Design draft — no code written against this yet
**Date:** 2026-07-21

This document defines the persistence schema and the scoring logic that decides who
appears on the Launchpad and why. It is the contract that the Vision prototype and
the SwiftUI layer will both build against.

---

## 1. Design constraints

Everything below is shaped by three non-negotiables from the product vision:

1. **On-device only.** No server, so no cross-user signal, no cloud embeddings, no
   remote model updates. Every score must be computable from local data in bounded time.
2. **Pull, not push.** The app is opened deliberately. Scores therefore need to be
   *fresh at open time*, not continuously recomputed. This favours cheap incremental
   updates in a background task over a heavy recompute.
3. **Explainable.** Every card says *why* it surfaced ("you haven't seen Sarah since
   March"). A black-box Core ML score can't do that alone, so the ranking is a
   transparent weighted sum, with Core ML confined to one narrow job (see §4.3).

---

## 2. Entities

### `Person`
The central entity. One row per human the user has a relationship with.

| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | Primary key |
| `displayName` | String | May start empty for a face cluster with no contact match |
| `contactIdentifier` | String? | `CNContact` identifier, if linked |
| — | — | *No `faceClusterID`.* A person owns **many** face groups; see `FaceGroup` below |
| `birthday` | Date? | From Contacts, or user-entered |
| `tier` | Int16 | User-assigned closeness, 0–3. See §4.1 |
| `cadenceTargetDays` | Int32? | Desired days between contact; nil = infer it |
| `isMuted` | Bool | Excluded from the Launchpad, never deleted |
| `createdAt` / `updatedAt` | Date | |

Relationships: `interactions` (→many `Interaction`), `appearances` (→many
`PhotoAppearance`), `sharedPlaces` (→many `Place`).

**Why `tier` is user-assigned, not inferred:** photo frequency is a terrible proxy
for closeness. You photograph a wedding you attended once far more than the sibling
you call weekly. Inferring closeness from photos would systematically surface
acquaintances over intimates — the exact failure mode that would make the app feel
stupid. Let the user state it; use signals for *timing*, not *ranking*.

### `Interaction`
An observed or user-logged contact event. Append-only.

| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `person` | → Person | |
| `date` | Date | |
| `kind` | Int16 | call, message, email, inPerson, calendarEvent, manual |
| `direction` | Int16 | outbound, inbound, mutual |
| `source` | Int16 | Provenance: userLogged, calendar, photoInference, launchpadAction |
| `confidence` | Double | 0–1; 1.0 for user-logged, lower for inferred |

**Note on a hard iOS limit:** there is *no* API for reading call history or iMessage
content. This is the single biggest constraint on the product and it is easy to
forget when designing. Interactions come from: (a) calendar events with the person as
an attendee, (b) inference from photos taken together, (c) the user tapping an action
in Hearth (we know we launched a call — not that it connected), and (d) manual entry.
The model must be honest that its picture of contact is partial, which is why
`confidence` exists and why the UI should say "since I last noticed" rather than
"since you last spoke."

### `PhotoAppearance`
One row per (photo, detected person) pair. The output of the Vision pipeline.

| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `person` | → Person? | Nil until the cluster is identified |
| `localIdentifier` | String | `PHAsset` identifier — we never copy the image |
| `captureDate` | Date | |
| `faceObservationData` | Binary | Serialised bounding box + landmarks |
| `embedding` | Binary | Face embedding for clustering. **Not** `VNFaceprint` — no such API exists; see [vision-findings.md](./vision-findings.md) §1 |
| `latitude` / `longitude` | Double? | From asset metadata, if present |
| `clusterID` | UUID? | Assigned by clustering, pre-identification |

Store `localIdentifier`, never pixels. Keeps the DB small and means revoking photo
permission genuinely revokes access.

### `FaceGroup`
One face cluster, belonging to a person. **A person may own several.**

| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `clusterID` | UUID | Cluster identity from the last scan, so groups survive a rescan |
| `createdAt` | Date | |
| `label` | String? | Optional user note, e.g. "as a baby" |
| `earliestCapture` / `latestCapture` | Date? | Span of member photos, for chronological ordering |

Relationships: `person` (→ Person), `appearances` (→many PhotoAppearance).

**Why an entity rather than a `faceClusterID` field on Person.** A single person
legitimately produces several clusters: a face that changes a lot over time will not
gather into one at any threshold that also keeps distinct people apart — measured, see
[vision-findings.md](./vision-findings.md) §4e. Forcing one cluster per person would make
the normal case look like an error the user must repair. Instead a person accumulates
groups, each internally clean, and the chronology is preserved rather than collapsed.

### `Place`
| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `name` | String | |
| `latitude` / `longitude` | Double | |
| `radiusMeters` | Double | Geofence size |
| `lastVisited` | Date? | |
| `visitCount` | Int32 | |
| `associatedPeople` | →many Person | People frequently photographed here |

### `Signal`
A materialised, explainable reason for surfacing someone. Regenerated by the
background task; cheap to read at app-open.

| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `person` | → Person | |
| `kind` | Int16 | birthday, overdueCadence, nearbyPlace, calendarUpcoming, anniversary |
| `score` | Double | Contribution to ranking |
| `reasonText` | String | Human copy shown on the card |
| `validUntil` | Date | Expiry, so stale signals self-clean |
| `dismissedAt` | Date? | User swiped it away |

Separating `Signal` from the scoring code means the Launchpad is a *dumb, fast read*
of pre-computed rows, and the reason string is generated where the context exists.

---

## 3. Schema diagram

```
                 ┌──────────────┐
       ┌────────▶│    Person    │◀────────┐
       │         └──────┬───────┘         │
       │                │                 │
┌──────┴──────┐  ┌──────┴───────┐  ┌──────┴────────┐
│ Interaction │  │    Signal    │  │   FaceGroup   │  (many per Person)
└─────────────┘  └──────────────┘  └───────┬───────┘
                                            │
                                    ┌───────┴───────┐
                                    │PhotoAppearance│
                                    └───────┬───────┘
                                            │ (lat/long)
                                     ┌──────┴──────┐
                                     │    Place    │
                                     └─────────────┘
```

---

## 4. Relationship scoring

### 4.1 Tiers and target cadence

`tier` sets a default expected contact interval. The user can override per person
via `cadenceTargetDays`.

| Tier | Meaning | Default cadence |
|---|---|---|
| 0 | Inner circle | 7 days |
| 1 | Close | 30 days |
| 2 | Kept warm | 90 days |
| 3 | Distant / dormant | 365 days |

### 4.2 The score

For each person, the Launchpad score is a weighted sum of active signals:

```
score(p) = w_cadence · overdueRatio(p)
         + w_birthday · birthdayProximity(p)
         + w_calendar · upcomingEvent(p)
         + w_place    · nearbyAffinity(p)
         − w_recent   · recentlyContacted(p)
         − w_fatigue  · surfacedRecently(p)
```

Where:

- `overdueRatio(p) = clamp(daysSinceLastInteraction / cadenceTargetDays, 0, 2)`
  Clamped at 2 so a friend you haven't seen in five years doesn't permanently
  monopolise the top slot. This matters: without the clamp the Launchpad converges
  to a static list of your most-neglected contacts and stops feeling alive.

- `birthdayProximity(p)` — a spike, non-zero only within 14 days, rising sharply
  inside 3 days.

- `upcomingEvent(p)` — a shared calendar event in the next 7 days. Prep prompts
  ("dinner with Joe Thursday") are among the most useful cards.

- `nearbyAffinity(p)` — non-zero only when the device is currently within a `Place`
  associated with `p`. Time-and-space dependent, so it must be computed at app-open,
  not in the background task.

- `recentlyContacted(p)` — strong negative if an interaction was logged in the last
  48h. Prevents nagging about someone you just called.

- `surfacedRecently(p)` — **fatigue term.** Decays a person's score each time they
  appear on the Launchpad without being acted on. Without this, the same three people
  sit at the top forever and the user learns to ignore the surface. This term is what
  makes the app feel responsive rather than nagging, and it's the one most likely to
  be omitted from a naive implementation.

### 4.3 Where Core ML actually belongs

The scoring above is deliberately a transparent weighted sum, not a learned model —
it must be explainable, and there is no training data on day one.

Core ML's genuinely useful job is narrower: **learning the user's personal cadence per
person** to replace the tier defaults. After enough observed interactions, the
interval between contacts with a given person has a distribution; the model predicts
the point at which contact is "overdue" relative to *that* person's actual rhythm
rather than a tier bucket. This is a small on-device regression, retrainable in a
background task, and it degrades gracefully — with no data, fall back to §4.1
defaults.

The cold-start reality is worth stating plainly: for the first several weeks the app
has almost no interaction history, so it is running on birthdays, calendar, and photo
back-history alone. The onboarding photo scan exists largely to manufacture a usable
history at install time.

---

## 5. Open questions

1. **Face cluster → contact matching.** *Partly answered by the
   [Vision prototype](./vision-findings.md).* Confirmed: PhotoKit does not expose the
   Photos "People" album, and Vision has no face-identity API at all, so onboarding
   labelling is unavoidable. Capped at 20 clusters in the prototype. Still open: whether
   20 questions is tolerable, and whether Contacts photos can pre-seed some guesses.
2. **Cadence for people with no digital trace.** Someone you only see in person and
   never photograph is invisible to every signal. Is manual entry enough?
3. **Should `Interaction` record failures?** If a launched call didn't connect, an
   inferred interaction actively hurts — it suppresses the person for 48h.
4. **iCloud sync.** The README promises optional sync. `NSPersistentCloudKitContainer`
   works, but faceprints are biometric-adjacent data; syncing them warrants care.

---

## 6. Next step

Per the agreed sequence, the Vision prototype (§ face clustering) is next. Its job is
to answer open question 1 and to establish whether clustering quality over a real
library is good enough to build on.
