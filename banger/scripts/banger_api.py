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
import argparse, json, os, subprocess, sys, urllib.request
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
    sent = _send_feedback(r["mbid"], rating)
    if sent:
        db.mark_feedback(con, r["id"]); con.commit()
    _line("ok", True)
    _line("rating", rating)
    _line("feedback_sent", sent)


def cmd_refresh():
    # "I'm done with this batch" -> clear audition, generate + download the next batch.
    _line("progress", "clear", "Clearing audition…")
    for f in audio_files(AUDITION):
        try:
            os.remove(f)
        except OSError:
            pass

    _line("progress", "batch", "Generating next batch…")
    mk = subprocess.run([sys.executable, os.path.join(SCRIPTS, "make_batch.py")],
                        capture_output=True, text=True)
    con = db.connect()
    latest = db.latest_batch(con)
    n = latest["number"] if latest else 1
    if mk.returncode != 0:
        con.close()
        _line("ok", False)
        _line("error", (mk.stderr or "make_batch failed").strip()[-400:])
        return

    _line("progress", "download", f"Downloading batch #{n}…")
    dl = subprocess.run([sys.executable, os.path.join(SCRIPTS, "download_batch.py"), str(n)],
                        capture_output=True, text=True)
    write_m3u("Audition", AUDITION)
    write_m3u("Library", LIBRARY)
    con.close()
    _line("ok", dl.returncode == 0)
    _line("batch_number", n)
    _line("audition_count", len(audio_files(AUDITION)))
    if dl.returncode != 0:
        _line("error", (dl.stderr or "download failed").strip()[-400:])


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("labels")
    p_label = sub.add_parser("label")
    p_label.add_argument("--file", required=True)
    p_label.add_argument("--rating", required=True, choices=["like", "dislike", "none"])
    sub.add_parser("refresh")
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
    con.close()


if __name__ == "__main__":
    main()
