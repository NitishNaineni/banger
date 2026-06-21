#!/usr/bin/env python3
"""
banger_api.py — machine-readable facade over the discovery pipeline, for the app.

Output is tab-separated lines (no JSON dep on the Vala side; filenames/artists/
messages never contain tabs). Every command writes ONLY these lines to stdout:

  status   -> one "<key>\\t<value>" line per field, plus "taste\\t<artist>\\t<count>" lines
  labels   -> one "<basename>\\t<like|dislike>" line per labelled track
  label --file <path> --rating like|dislike|none  -> "ok\\t<bool>" [+ "rating"/"error"]
  refresh  -> "progress\\t<phase>\\t<msg>" lines, then "ok\\t<bool>" + "batch_number\\t<n>"

Tracks are matched by file BASENAME, so a rating resolves whether the track is
played from ~/Music/audition/ or its ~/Music/library/ copy (same filename).

Run under `uv run --project <bangerdir>` so troi/streamrip and config are available.
"""
import argparse, json, os, pathlib, subprocess, sys, urllib.request
from urllib.parse import unquote, urlparse
import db
from _paths import AUDITION, LIBRARY, audio_files, load_config, write_m3u

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
LB_FEEDBACK = "https://api.listenbrainz.org/1/feedback/recording-feedback"


def _line(*fields):
    """Emit one tab-separated record line and flush (keeps stdout a clean stream)."""
    out = []
    for f in fields:
        if isinstance(f, bool):
            f = "true" if f else "false"
        out.append("" if f is None else str(f))
    sys.stdout.write("\t".join(out) + "\n")
    sys.stdout.flush()


def _lb_token():
    return load_config().get("listenbrainz", {}).get("token", "")


def _send_feedback(mbid, rating):
    """ListenBrainz loved(+1)/hated(-1)/clear(0). Best-effort; returns True if sent."""
    token = _lb_token()
    if not token or not mbid:
        return False
    score = {"like": 1, "dislike": -1}.get(rating, 0)
    body = json.dumps({"recording_mbid": mbid, "score": score}).encode()
    req = urllib.request.Request(
        LB_FEEDBACK, data=body, method="POST",
        headers={"Authorization": f"Token {token}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=12)
        return True
    except Exception:
        return False


def _flush_pending(con):
    """Send any like/dislike feedback not yet on ListenBrainz (offline backlog).

    Stops at the first failure (the API/network is likely down) and leaves the
    rest as feedback=0 to retry next time. Returns how many were sent."""
    sent = 0
    rows = con.execute("SELECT id, mbid, label FROM tracks "
                       "WHERE label IS NOT NULL AND feedback = 0 AND mbid != ''").fetchall()
    for r in rows:
        if _send_feedback(r["mbid"], r["label"]):
            db.mark_feedback(con, r["id"]); sent += 1
        else:
            break
    if sent:
        con.commit()
    return sent


def _localpath(p):
    """Normalize a percent-encoded file:// URI (as GIO emits) to a plain filesystem path."""
    return unquote(urlparse(p).path) if p.startswith("file://") else p


def _find_track(con, path):
    """Find a track row by the basename of a file path (audition or library copy)."""
    base = os.path.basename(_localpath(path))
    for r in con.execute("SELECT * FROM tracks WHERE file != '' ORDER BY id DESC"):
        if os.path.basename(r["file"]) == base:
            return r
    return None


def cmd_status(con):
    latest = db.latest_batch(con)
    total = con.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
    like = con.execute("SELECT COUNT(*) FROM tracks WHERE label='like'").fetchone()[0]
    dislike = con.execute("SELECT COUNT(*) FROM tracks WHERE label='dislike'").fetchone()[0]
    _line("configured", bool(_lb_token()))
    _line("batches", con.execute("SELECT COUNT(*) FROM batches").fetchone()[0])
    _line("batch_number", latest["number"] if latest else "")
    _line("downloaded", bool(latest and latest["downloaded_at"]))
    _line("total_seen", total)
    _line("audition_count", len(audio_files(AUDITION)))
    _line("library_count", len(audio_files(LIBRARY)))
    _line("liked", like)
    _line("disliked", dislike)
    _line("pending", total - like - dislike)
    for r in con.execute(
            "SELECT artist, COUNT(*) c FROM tracks WHERE label='like' AND artist != '' "
            "GROUP BY artist ORDER BY c DESC LIMIT 6"):
        _line("taste", r["artist"], r["c"])


def cmd_labels(con):
    for r in con.execute("SELECT file, label FROM tracks WHERE label IS NOT NULL AND file != ''"):
        _line(os.path.basename(r["file"]), r["label"])


def cmd_label(con, path, rating):
    r = _find_track(con, path)
    if r is None:
        _line("ok", False)
        _line("error", "track not found")
        return
    label = None if rating == "none" else rating
    # set ONLY the label; keep `file` as the audition path so basename lookups still work
    con.execute("UPDATE tracks SET label=?, feedback=0, updated_at=datetime('now') WHERE id=?",
                (label, r["id"]))
    con.commit()
    # un-rating clears LB feedback (best-effort); like/dislike go through the
    # pending flush, so an offline tap is cached (feedback=0) and retried later.
    if rating == "none":
        _send_feedback(r["mbid"], "none")
    flushed = _flush_pending(con)
    # keep the playlists in sync with the like/dislike just made
    write_m3u("Audition", AUDITION)
    write_m3u("Library", LIBRARY)
    _line("ok", True)
    _line("rating", rating)
    _line("flushed", flushed)


def cmd_flush(con):
    _line("flushed", _flush_pending(con))


def cmd_refresh():
    # "I'm done with this batch" -> clear audition, generate + download the next batch.
    # Progress lines: progress\t<message>\t<done>\t<total>  (done/total optional).
    con0 = db.connect()
    _flush_pending(con0)   # ship any offline backlog before moving on
    con0.close()

    # Generate the next batch FIRST; only clear audition once we actually have a
    # new batch to download (a make_batch failure must not empty the tab).
    _line("progress", "Generating next batch…")
    # A manageable audition batch — make_batch defaults to 100, which is far too
    # many to download + review per Refresh.
    mk = subprocess.run([sys.executable, os.path.join(SCRIPTS, "make_batch.py"), "--size", "50"],
                        capture_output=True, text=True)
    con = db.connect()
    latest = db.latest_batch(con)
    n = latest["number"] if latest else 1
    if mk.returncode != 0:
        con.close()
        _line("ok", False)
        _line("error", (mk.stderr or "make_batch failed").strip()[-400:])
        return

    _line("progress", "Clearing audition…")
    for f in audio_files(AUDITION):
        try:
            os.remove(f)
        except OSError:
            pass

    # stream per-track download progress from download_batch (BANGER_PROGRESS mode)
    env = dict(os.environ)
    env["BANGER_PROGRESS"] = "1"
    proc = subprocess.Popen(
        [sys.executable, os.path.join(SCRIPTS, "download_batch.py"), str(n)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    for raw in proc.stdout:
        parts = raw.rstrip("\n").split("\t", 4)
        if len(parts) == 5 and parts[0] == "DL":
            done, total, saved, desc = parts[1], parts[2], parts[3], parts[4]
            uri = pathlib.Path(saved).as_uri() if saved else ""
            # progress\t<track>\t<done>\t<total>\t<file uri> — the app formats the
            # "n/total · ETA" line itself; uri lets it load each track as it lands.
            _line("progress", desc, done, total, uri)
    rc = proc.wait()
    write_m3u("Audition", AUDITION)
    write_m3u("Library", LIBRARY)
    con.close()
    _line("ok", rc == 0)
    _line("batch_number", n)
    _line("audition_count", len(audio_files(AUDITION)))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("labels")
    p_label = sub.add_parser("label")
    p_label.add_argument("--file", required=True)
    p_label.add_argument("--rating", required=True, choices=["like", "dislike", "none"])
    sub.add_parser("refresh")
    sub.add_parser("flush")
    args = ap.parse_args()

    if args.cmd == "refresh":
        cmd_refresh()
        return
    con = db.connect()
    if args.cmd == "status":
        cmd_status(con)
    elif args.cmd == "labels":
        cmd_labels(con)
    elif args.cmd == "label":
        cmd_label(con, args.file, args.rating)
    elif args.cmd == "flush":
        cmd_flush(con)
    con.close()


if __name__ == "__main__":
    main()
