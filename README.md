# banger

A cross-device, local-first music **discovery loop** built around a personal FLAC
library and [ListenBrainz](https://listenbrainz.org). You audition recommended tracks,
keep what you like (👍) and drop what you don't (👎), and that taste signal trains the
next batch — on whichever device you're holding.

## Repository layout

```
banger/
├── desktop/    The desktop hub — a custom G4Music fork (Vala/GTK4) with the banger
│               discovery UI, plus the Python pipeline it drives (banger/scripts):
│               Troi/ListenBrainz recommendations → streamrip/Deezer download →
│               audition → like/dislike → embedded word-level karaoke lyrics.
│               THIS is where downloads happen (streamrip + Deezer are desktop-only).
├── android/    The phone app — a fork of Auxio (Kotlin) that plays the synced
│               library and mirrors the banger experience: 👍/👎, karaoke lyrics,
│               and ListenBrainz feedback + scrobbling. (No downloading on-device.)
└── docs/       Architecture + design notes (see docs/architecture.md).
```

## How the two devices stay in sync

- **Files** — Syncthing mirrors `~/Music/library` + `~/Music/audition` between the
  Fedora hub and the Android phone, **LAN-only** (no relays / global discovery), so
  device↔device sync happens only on the same network.
- **State (likes/dislikes, etc.)** — the discovery DB syncs **bidirectionally** as a
  CRDT (last-writer-wins per track), so either device can sort and both converge —
  offline-tolerant, no cloud, no fragile shared SQLite file. See `docs/architecture.md`.
- **Taste** — both devices write feedback + scrobbles to **ListenBrainz** (a write-only
  taste sink; the synced DB is the rich shared state). Network-down is handled by
  offline queues that retry until delivered.

## Build

- Desktop: `meson setup desktop/builddir desktop && ninja -C desktop/builddir install`
- Android: see `android/README.md`.

The desktop player installs to `~/.local/bin/g4music` with its bundled pipeline at
`~/.local/share/g4music/banger`. Secrets (Deezer ARL, ListenBrainz token) live in
`~/.config/banger/config.toml` and are never committed.
