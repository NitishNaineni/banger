# banger — discovery loop baked into G4Music

This is a fork of [G4Music](https://github.com/neithern/g4music) that builds a
personal, fully-local **music-discovery loop** into the player itself. It keeps the
upstream app intact and adds everything in new files, so it stays mergeable with
upstream.

## What it adds

- **👍 / 👎 on the play bar** — like or dislike the *currently playing* track.
  - **Like** copies the audition track into `~/Music/library/` (it now lives in both)
    and sends a ListenBrainz *loved* (+1). The library is just your "likes".
  - **Un-like** removes the library copy only; the audition copy stays.
  - **Dislike** records it (ListenBrainz *hated*, −1); the file stays in audition.
  - Neither = undecided. The toggles are mutually exclusive and reflect each track's
    saved rating as you play.
- **An Audition page** — a playable track list of the current batch, with a **Refresh**
  button ("done with this batch"): it clears the audition folder and downloads the next
  batch (generated from your taste), showing a live progress bar. Audition is this tab,
  not an `.m3u` playlist.

The discovery logic (ListenBrainz/troi for recommendations, streamrip+Deezer for
downloads, SQLite for state) is the **bundled Python pipeline** under `banger/`. The
app drives it; it never reimplements it.

## Architecture

```
src/banger/                         all the Vala glue (isolated, new files)
  banger-service.vala   runs the sidecar via `uv run`, label cache, like/dislike, refresh
  audition-page.vala    the Audition page (track list + Refresh)
banger/                             the bundled Python pipeline (copied from the standalone repo)
  scripts/banger_api.py   tab-separated facade the app calls: status / labels / label / refresh
  scripts/*.py            make_batch, download_batch, capture_labels, db, _paths
```

**User state lives outside the source tree** (so rebuilds/merges never touch it):

| What | Location | Override |
|---|---|---|
| Label DB | `~/.local/share/banger/discovery.db` | `BANGER_DATA` |
| Secrets (Deezer ARL, LB token) | `~/.config/banger/config.toml` | `BANGER_CONFIG` |
| Bundled pipeline | `$datadir/g4music/banger` (installed) | `BANGER_HOME` |

The app↔sidecar protocol is **tab-separated lines** (no `json-glib` build dep); tracks
are matched by file basename so a rating resolves whether the track is played from
`audition/` or its `library/` copy.

## Upstream touch-points (for re-merging)

Everything else is new files. Only these upstream files are edited — all small and in
stable spots. After `git merge upstream/master`, re-apply only if these conflict:

| File | Edit |
|---|---|
| `meson.build` | `install_subdir('banger', …)` |
| `src/meson.build` | add `banger/banger-service.vala`, `banger/audition-page.vala` to `sources` |
| `src/gresource.xml` | add the two `thumbs-*-symbolic.svg` icons |
| `src/ui/music-widgets.vala` | `PageName.AUDITION` constant |
| `src/ui/store-panel.vala` | one `add_titled(new AuditionPage(_app), …)` line |
| `src/ui/play-bar.vala` | the 👍/👎 toggles + `music_changed`/`labels_changed` sync |

## Build & run (native)

```bash
meson setup builddir --prefix="$HOME/.local"
ninja -C builddir install        # installs g4music + banger/ to ~/.local/share/g4music/banger
g4music
```

Requires `uv` on `PATH` (for the Python sidecar) and, for downloads, a Deezer ARL
configured in streamrip and a ListenBrainz token in `~/.config/banger/config.toml`.

For development you can point at the in-tree pipeline instead of installing:

```bash
BANGER_HOME="$PWD/banger" ./builddir/src/g4music
```

## Staying current with upstream

```bash
git remote add upstream https://github.com/neithern/g4music.git   # once
git fetch upstream && git merge upstream/master
```

Because the additions are isolated, merges touch only the few files above.

## Note: file monitoring

banger does its own file management and reloads, so it runs with
`monitor-changes` **off** (the schema default). Leave it off: with it on, a batch
download dumps ~100 files into the watched audition folder at once, and G4Music's
loader isn't safe for concurrent `on_file_added` (it races on the unlocked
`Album._musics` hashtable and segfaults). The proper upstream fix is to lock those
add paths; until then, keep `monitor-changes` disabled.
