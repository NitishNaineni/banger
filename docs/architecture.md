# banger — cross-device architecture

## Device roles (deliberate split)

| Capability | Desktop hub (Fedora) | Android phone |
|---|---|---|
| Play the local FLAC library | ✅ G4Music fork | ✅ Auxio fork |
| 👍/👎 like / dislike | ✅ | ✅ |
| Word-level karaoke lyrics (embedded FLAC `LYRICS` tag) | ✅ | ✅ (to build) |
| ListenBrainz feedback + scrobble | ✅ | ✅ (native or Pano Scrobbler) |
| **Refresh / download next batch** (Troi → streamrip → Deezer) | ✅ **only here** | ❌ not feasible on-device |

**Why downloads are desktop-only:** the discovery pipeline is Python + streamrip + a
Deezer ARL. There is no viable on-device Deezer downloader, so the phone consumes the
*synced* library and contributes taste; new music is fetched at the desktop.

## Sync backbone

### 1. Files — Syncthing, LAN-only
`~/Music/library` and `~/Music/audition` mirror between hub and phone. Lock to LAN:
disable global discovery + relaying so device↔device transfer only happens on the same
network. Keep 30-day trashcan versioning (an accidental delete must not be read as a
dislike — see [[deletion-as-label]] below).

### 2. State — bidirectional CRDT sync of the discovery DB
The cross-device state that matters is **small and simple**: per-track `label`
(like / dislike / none) and its ListenBrainz delivery status. Conflicts resolve as
**last-writer-wins per track** — which is exactly a CRDT LWW-register.

**Researched options (2026):**
- **cr-sqlite** (vlcn-io) — the canonical peer-to-peer CRDT *extension*: turns tables
  into row-level LWW CRDTs, runtime-loadable into SQLite/libSQL, no central server.
  Generic (syncs the whole DB) but: Android needs the native ext built + loaded,
  ~2.5× insert cost, and project maintenance is uneven.
- **sqlite-sync** (sqlite.ai) — production-ready 2026, multi-platform incl. Android,
  but oriented to syncing *through* a hub (SQLite Cloud / Postgres / Supabase), not
  pure P2P LAN.
- **Turso / libSQL, SQLSync, PowerSync** — all assume a server/primary; not P2P.

**Chosen approach — a focused LWW-register CRDT carried over Syncthing:**
Each device appends its label changes to a **per-device, append-only changelog**
(`track-key, label, hybrid-logical-clock, device-id`) under a synced folder. Syncthing
(already LAN-only, offline-tolerant) carries each device's log; every device applies
peers' logs by last-writer-wins to rebuild the shared label state. No shared/locked
SQLite file (so no corruption), trivially offline, and it reuses the transport we
already run. Escalate to **cr-sqlite** only if we later need the *entire* DB to be a
live CRDT rather than just the label state.

### 3. Taste — ListenBrainz (write-only sink)
Both devices push love/hate + scrobbles to ListenBrainz. It is treated as **write-only**:
the synced DB is the authoritative shared state; LB is the global taste profile that the
recommender reads. LB dedupes listens on `(timestamp, user, recording MSID)`, so the
same track played near-simultaneously on both devices is not double-counted.

## Network-down handling
- **Syncthing**: inherently offline — syncs whenever both devices are next on the LAN.
- **CRDT label sync**: append-only logs converge whenever logs next propagate; order-
  independent, so any delivery sequence is safe.
- **ListenBrainz**: desktop reconciles via the `lb_sent` desired-vs-delivered column
  (retries on startup / network-recovery / each action); the phone queues offline
  (native queue or Pano Scrobbler) and flushes on reconnect.

## <a name="deletion-as-label"></a>Deletion-as-label integrity
Sorting from the phone uses file moves (audition→library = like) and the desktop's
folder-watch reconcile imports them. A *delete* as dislike must be captured into the
CRDT log **before** Syncthing propagates the deletion everywhere; trashcan versioning is
the safety net against an accidental mass-delete becoming mass-hate.
