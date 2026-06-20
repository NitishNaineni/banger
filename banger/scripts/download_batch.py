#!/usr/bin/env python3
"""
download_batch.py — Fetch a batch via Deezer (download backend only).

Two phases, per the speed/ban research:
  1. RESOLVE — map each candidate to a Deezer track id via the PUBLIC search API.
     This is credential-free and IP-bound, so it's safe to PARALLELIZE (bounded
     pool + full-jitter backoff on Deezer's "Quota limit exceeded" error).
  2. DOWNLOAD — stream lossless FLAC with the personal ARL. This is the account-
     ban-risk step, so it stays conservative (serial, one track at a time).

Records the deezer_id + real saved file path back into the DB.

Usage:
    uv run python scripts/download_batch.py <batch-number>
"""
import argparse, json, os, random, re, subprocess, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
import db
from _paths import AUDITION, audio_files, write_m3u
from _ui import console, ok, download_progress

ROOT = os.path.join(os.path.dirname(__file__), "..")
SEARCH_WORKERS = 6          # safe parallel pool for the public search API


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def _clean(title):
    t = re.sub(r"\([^)]*\)|\[[^\]]*\]", "", title)
    t = re.sub(r"\s*-\s*.*(remaster|version|edit|mix).*", "", t, flags=re.I)
    return t.strip()


def _backoff(attempt):
    time.sleep(random.uniform(0, min(8.0, 0.4 * 2 ** attempt)))   # full jitter


def _search(artist, title):
    q = urllib.parse.quote(f"{artist} {title}")
    for attempt in range(4):
        try:
            with urllib.request.urlopen(
                    f"https://api.deezer.com/search?q={q}&limit=3", timeout=12) as r:
                d = json.loads(r.read())
            if isinstance(d, dict) and d.get("error"):    # code 4: quota exceeded
                _backoff(attempt); continue
            na = norm(artist)
            for res in d.get("data", []):
                if not na or na in norm(res.get("artist", {}).get("name", "")) \
                        or norm(res.get("artist", {}).get("name", "")) in na:
                    return str(res["id"])
            return ""
        except Exception:
            _backoff(attempt)
    return ""


def deezer_id(artist, title):
    return _search(artist, title) or _search(artist, _clean(title))


def resolve_all(rows):
    """Resolve every track's Deezer id in parallel (safe: public API)."""
    with ThreadPoolExecutor(max_workers=SEARCH_WORKERS) as ex:
        ids = list(ex.map(lambda r: deezer_id(r["artist"], r["title"]), rows))
    return dict(zip((r["id"] for r in rows), ids))


def run(con, n, rip):
    os.makedirs(AUDITION, exist_ok=True)
    rows = db.batch_tracks(con, n)

    with console.status(f"[cyan]resolving {len(rows)} tracks on Deezer…"):
        resolved = resolve_all(rows)

    n_ok = unmatched = fail = 0
    with download_progress() as prog:                 # downloads stay serial (ban-safe)
        task = prog.add_task("starting…", total=len(rows))
        for r in rows:
            prog.update(task, description=f"{r['artist']} – {r['title']}"[:42])
            did = resolved.get(r["id"], "")
            if not did:
                unmatched += 1
                db.set_download(con, r["id"], "", "")
                prog.advance(task); continue
            before = set(audio_files(AUDITION))
            # --no-db: ignore streamrip's own download-history (we dedup via our DB;
            # otherwise streamrip skips anything downloaded in a past session).
            subprocess.run([rip, "--no-db", "--folder", AUDITION, "id", "deezer", "track", did],
                           capture_output=True)
            new_files = sorted(set(audio_files(AUDITION)) - before)
            saved = new_files[0] if new_files else ""
            n_ok += bool(saved); fail += not saved
            db.set_download(con, r["id"], did, saved)
            prog.advance(task)
    db.mark_downloaded(con, n)
    con.commit()
    write_m3u("Audition", AUDITION)
    ok(f"[green]{n_ok}[/] downloaded  ·  [yellow]{unmatched}[/] no match  ·  [red]{fail}[/] failed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("batch", type=int)
    ap.add_argument("--rip", default=os.path.join(ROOT, ".venv", "bin", "rip"))
    a = ap.parse_args()
    rip = a.rip if os.path.exists(a.rip) else "rip"
    if subprocess.run([rip, "--version"], capture_output=True).returncode != 0:
        sys.exit("streamrip not found / not configured. Run `rip config` and set your Deezer ARL.")
    run(db.connect(), a.batch, rip)


if __name__ == "__main__":
    main()
