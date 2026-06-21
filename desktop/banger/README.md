# banger

A personal, fully-local **active-learning music discovery** loop: get a broad
ranked pool of songs, audition a batch, keep what you like / delete the rest,
and let those binary labels sharpen the next batch. Rinse and repeat — the
picks get more "you" over time.

Runs entirely on Linux (Fedora). No Spotify audio API (it's dead), no cloud
required for the core loop.

## The loop

```
 make_batch ──▶ candidates in the DB           (generated fresh from YOUR labels)
        │         cold start: community top recordings (neutral, un-curated)
        │         after that: LB Radio "more like what you kept"
        │
 download ──▶ ~/Music/audition/                (streamrip+Deezer; "Audition" playlist)
        │
   sort the Audition playlist by hand:
        move → ~/Music/library/  = like   |   delete = dislike   |   leave = undecided
        │  (listen as many times as you want; nothing is judged until you sort)
        │
 capture ──▶ labels in the DB
        │      └▶ feedback to ListenBrainz: like = loved(+1), dislike = hated(-1)
        │         → hated tracks get filtered/down-weighted in your recs
        └────────────▶ back to make_batch (smarter next time)
```

The single command `banger` runs make → (capture, if you've sorted) → download.

## Pure emergence — no explicit rules

There is **no genre list, no language filter, no thresholds I hand-set**. Each
batch is derived only from what you've kept and deleted:

- **Batch 1 (cold start):** the ListenBrainz community's top *recordings* — a
  neutral, un-curated seed. Genre/language diversity (K-pop, etc.) shows up on its
  own from the data; nothing is specified.
- **Batch 2+:** `make_batch` builds an LB Radio prompt from your kept artists
  (`artist:(…)` + `stats:(you)` + `recs:(you)`) and avoids artists you've rejected.
  It stratifies each batch **50/30/20 across LB Radio's easy/medium/hard modes** —
  which sample the head / middle / tail of the ranked candidate list (most-similar
  + popular → far-but-related + deep cuts). Half the batch is medium+hard on
  purpose, so it keeps exploring instead of tunnelling into one neighbourhood.

Language and genre preferences are **emergent** — you stop gravitating toward what
you don't like, so it stops appearing. You never specify anything.

## Folders & playlists

Everything lives under `~/Music` so it shows up in G4Music (and Syncthing later):

| Path | Playlist | Role |
|---|---|---|
| `~/Music/audition/` | **Audition** | current batch under review (Linux-only scratch) |
| `~/Music/library/`  | **Library**  | tracks you kept — your real, growing collection |
| `~/Music/Playlists/*.m3u` | — | auto-generated so both appear as named playlists |

You move keepers `audition → library` **by hand** — that *is* the "like" action;
deletes are dislikes; whatever you leave in `audition/` is undecided and comes back
next round. Languages are **not** filtered — world genres (K/J-pop, Bollywood,
Latin…) are in the pool on purpose; your sorting teaches it your taste passively.

## Locked architecture decisions

| Role | Choice | Why |
|---|---|---|
| Discovery / recommendation | **ListenBrainz + Troi (LB Radio)** | Tag prompts cold-start with zero history; `easy→hard` mode = explore/exploit dial; personalized `recs:`/`stats:` as scrobbles grow. **Deezer is never used for discovery.** |
| Download backend | **streamrip + Deezer** | Deezer covers ~97% of mainstream taste (measured); CD-quality FLAC is transparent on real gear; streamrip is the reliable CLI |
| Player | **G4Music** | Fast, modern, ReplayGain, best-maintained native option |
| Scrobble / tracking | **ListenBrainz** (via `rescrobbled`, whitelisted to G4Music only) | Open data, MusicBrainz IDs, real recommendation API — feeds the model. `mpris-scrobbler` couldn't parse G4Music's MPRIS, and a whitelist keeps browser/Spotify out |
| Taste model | cold-start diversity → **PU classifier** (positive-unlabeled) | You start with only "likes"; never treat un-auditioned songs as dislikes |
| Sync (later) | **Syncthing** (LAN-only) + Pano Scrobbler on Android | Mirror the kept library to phone; one unified ListenBrainz profile |

## Setup

Managed entirely with [uv](https://docs.astral.sh/uv/):

```bash
uv sync          # creates .venv, installs troi + streamrip from uv.lock
cp config.example.toml config.toml   # then add your Deezer ARL / LB token
ln -sf "$PWD/banger" ~/.local/bin/banger   # install the `banger` command
```

Now you can run it as a program from anywhere:

```bash
banger            # run a loop turn
banger --dry-run  # preview the steps, change nothing
banger status     # pretty state summary
banger batch      # just generate the next batch
banger help
```

## Usage

**`banger` does a whole turn of the loop** (rich live output):

```bash
banger              # process culls -> next batch -> download
banger --dry-run    # show the steps, change nothing
banger status       # pretty summary of state (batches, taste)
```

`banger` figures out the state: first run just populates the Audition playlist;
every run after that processes your culls (labels + love/hate feedback + library
reconciliation), generates the next batch from your taste, and downloads it.

Between runs you **sort the Audition playlist by hand** (listen as many times as
you want first — no snap judgments):

| Your action on a track | Means |
|---|---|
| **move it to `~/Music/library/`** | **like** — you want to keep it |
| **delete it** | **dislike** |
| **leave it in `~/Music/audition/`** | **undecided** — carries to the next round |

Then run `banger` again — it reads where you put each file. Deleting a track later
from **Library** also counts: it's reconciled to a dislike on the next turn.

The individual steps are still runnable on their own (they take a batch number):

```bash
uv run python scripts/make_batch.py --size 100   # prints the new batch number
uv run python scripts/download_batch.py 1
uv run python scripts/capture_labels.py 1
```

All pipeline state — batches, candidates, downloads, labels, feedback — lives in
one SQLite file, **`data/discovery.db`** (see `scripts/db.py`). The `audition/`
and `library/` folders + M3U playlists are just what G4Music plays; the DB is the
source of truth.

## Status

- [x] Emergent `make_batch` — no genres/languages/rules; derived from labels
- [x] Cold-start seed = ListenBrainz community top recordings (`data/batch_01.csv`, 100)
- [x] Deezer = download backend only (resolve artist/title → Deezer ID → streamrip)
- [x] streamrip + Deezer ARL wired and validated
- [x] `rescrobbled` → ListenBrainz (`knightron`), whitelisted to G4Music only (verified scrobble landed)
- [x] audition/library folders + M3U playlists; keepers graduate on label capture
- [ ] **first real cycle** — download a batch (only on explicit go), audition, cull
- [ ] personalized prompts (`recs:`/`stats:`) strengthen as scrobbles accumulate
- [ ] PU classifier + audio embeddings (Essentia/CLAP) for sharper ranking
- [x] Syncthing bidirectional sync (PC ↔ phone) for library + audition — sort batches from either device
- [ ] Pano Scrobbler on Android (unified ListenBrainz profile across phone + desktop)

> Note: ListenBrainz's *hosted* LB Radio endpoint was 503 during setup; Troi runs
> the same logic locally, so discovery works regardless.

## Notes

- `config.example.toml` — copy to `config.toml`, add your Deezer ARL /
  ListenBrainz token. **Never commit `config.toml`** (gitignored).
- `audition/` is scratch space (gitignored) — downloads land here for culling.
