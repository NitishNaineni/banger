#!/usr/bin/env python3
"""
make_batch.py — Generate the next batch, derived purely from your labels.

No genres, languages, or hand-set rules. Cold start (no likes) = ListenBrainz
community top recordings; once you have likes = LB Radio prompt from your kept
artists (+ stats:/recs: once your account has enough history). All state lives
in the SQLite DB (db.py); dedup is by recording MBID.

Usage:
    uv run python scripts/make_batch.py            # next batch
    uv run python scripts/make_batch.py --mode medium --size 100
"""
import argparse, json, os, subprocess, tempfile, urllib.request
import db
from _paths import load_config, norm
from _ui import console, ok, warn

TROI = os.path.join(os.path.dirname(__file__), "..", ".venv", "bin", "troi")
LB = "https://api.listenbrainz.org/1"
STATS_MIN_LISTENS = 100
USER = ""

# Explore/exploit mix: LB Radio modes sample head/middle/tail of the ranked
# candidate list (easy = most similar + popular, hard = far-but-related + deep
# cuts). Stratifying across all three keeps batches enjoyable AND prevents the
# filter-bubble. ~half the batch is medium+hard = deliberate discovery.
EXPLORE_MIX = [("easy", 0.5), ("medium", 0.3), ("hard", 0.2)]


def _load_user():
    global USER
    USER = load_config().get("listenbrainz", {}).get("username", "")


def clean_artist(a):
    import re
    return re.sub(r'[(),:#!"\']', " ", a or "").strip()


def _get(url):
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return json.load(r)
    except Exception:
        return {}


def listen_count(user):
    return _get(f"{LB}/user/{user}/listen-count").get("payload", {}).get("count", 0)


def sitewide_recordings(n):
    d = _get(f"{LB}/stats/sitewide/recordings?count={n}&range=month")
    return [{"artist": r.get("artist_name", ""), "title": r.get("track_name", ""),
             "album": r.get("release_name", ""), "mbid": r.get("recording_mbid", "")}
            for r in d.get("payload", {}).get("recordings", [])]


def lb_radio(prompt, mode):
    if not prompt.strip():
        return []
    with tempfile.TemporaryDirectory() as td:
        subprocess.run([TROI, "playlist", "--save", "--quiet", "lb-radio", mode, prompt],
                       cwd=td, capture_output=True, text=True)
        jspf = os.path.join(td, "playlist_000.jspf")
        if not os.path.exists(jspf):
            return []
        d = json.load(open(jspf))
        out = []
        for t in d.get("playlist", {}).get("track", []):
            ids = t.get("identifier", [])
            out.append({"artist": t.get("creator", ""), "title": t.get("title", ""),
                        "album": t.get("album", ""),
                        "mbid": ids[0].rsplit("/", 1)[-1] if ids else ""})
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=100)
    ap.add_argument("--mode", default=None, choices=["easy", "medium", "hard"],
                    help="force a single mode; default = 50/30/20 easy/medium/hard mix")
    a = ap.parse_args()
    _load_user()

    con = db.connect()
    seeds = db.liked_artists(con)
    seen = db.seen_mbids(con)
    terms = [f"artist:({clean_artist(x)})" for x in seeds[:8] if clean_artist(x)]
    picked, batch = set(), []

    def take(recs, limit):
        for r in recs:
            key = r["mbid"] or (norm(r["title"]), norm(r["artist"]))
            if not r["title"] or key in picked or (r["mbid"] and r["mbid"] in seen):
                continue
            picked.add(key); batch.append(r)
            if len(batch) >= limit:
                return True
        return False

    if not terms:
        with console.status("[cyan]cold-start · ListenBrainz community top recordings…"):
            take(sitewide_recordings(a.size * 3), a.size)
        source = "cold-start"
    else:
        base = " ".join(terms)
        prompt = base
        if USER and listen_count(USER) >= STATS_MIN_LISTENS:
            prompt = f"{base} stats:({USER}):1 recs:({USER}):2"
        # stratified explore/exploit: fill cumulative quotas per mode
        modes = [(a.mode, 1.0)] if a.mode else EXPLORE_MIX
        with console.status("[cyan]asking ListenBrainz for more like what you kept…"):
            cum = 0
            for mode, frac in modes:
                cum = min(a.size, cum + round(a.size * frac))
                for _ in range(3):
                    if take(lb_radio(prompt, mode), cum):
                        break
            if not batch and prompt != base:        # stats/recs prompt empty -> plain seeds
                for _ in range(5):
                    if take(lb_radio(base, "easy"), a.size):
                        break
        source = f"your likes · {a.mode}" if a.mode else "your likes · 50/30/20 explore"

    n = db.new_batch(con, a.mode or "mix")
    for r in batch:
        db.add_candidate(con, n, r)
    con.commit()
    if not batch:
        warn("produced 0 tracks — check network / ListenBrainz availability")
    ok(f"batch [bold]#{n}[/]  ·  [green]{len(batch)}[/] tracks  ·  [dim]{source}[/]")
    print(n)   # last line = the batch number (for standalone/CLI use)


if __name__ == "__main__":
    main()
