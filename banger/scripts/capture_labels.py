#!/usr/bin/env python3
"""
capture_labels.py — turn how you SORT the audition into labels.

You sort by hand, on your own clock (listen as many times as you want first):
    move a track to ~/Music/library/   -> LIKE      (you want to keep it)
    delete it                          -> DISLIKE
    leave it in ~/Music/audition/      -> undecided  (carries to the next round)

Plus library reconciliation: a kept track you LATER delete from library/ flips to
dislike. Sends ListenBrainz love(+1)/hate(-1) on every label change. Processes
ALL still-undecided downloaded tracks (so carryovers from old batches resolve).

Usage:
    uv run python scripts/capture_labels.py
"""
import argparse, json, os, random, time, urllib.error, urllib.request
import db
from _paths import AUDITION, LIBRARY, load_config, write_m3u
from _ui import ok, info

LB_FEEDBACK = "https://api.listenbrainz.org/1/feedback/recording-feedback"


def _lb_token():
    return load_config().get("listenbrainz", {}).get("token", "")


def _post(req):
    for attempt in range(4):
        try:
            urllib.request.urlopen(req, timeout=12)
            return True
        except urllib.error.HTTPError as e:
            if e.code != 429:
                return False
            wait = e.headers.get("Retry-After") or e.headers.get("X-RateLimit-Reset-In") or "1"
            try:
                wait = float(wait)
            except ValueError:
                wait = 1.0
            time.sleep(wait + random.uniform(0, 0.5))
        except Exception:
            time.sleep(random.uniform(0, 0.5))
    return False


def send_feedback(con, changes):
    """changes: list of (track_id, mbid, label). +1/-1, marks feedback in DB."""
    token = _lb_token()
    sent = skip = 0
    for tid, mbid, label in changes:
        if not token or not mbid:
            skip += 1; continue
        body = json.dumps({"recording_mbid": mbid,
                           "score": 1 if label == "like" else -1}).encode()
        req = urllib.request.Request(LB_FEEDBACK, data=body, method="POST",
              headers={"Authorization": f"Token {token}", "Content-Type": "application/json"})
        if _post(req):
            db.mark_feedback(con, tid); sent += 1
        else:
            skip += 1
    return sent, skip


def main():
    argparse.ArgumentParser().parse_args()   # no args; accept -h
    con = db.connect()
    changes = []
    likes = dislikes = undecided = 0

    # every downloaded track that hasn't been decided yet (any batch)
    pending = con.execute("SELECT * FROM tracks WHERE file != '' AND label IS NULL").fetchall()
    for r in pending:
        lib = os.path.join(LIBRARY, os.path.basename(r["file"]))
        if os.path.exists(lib):              # you moved it to library -> like
            db.set_label(con, r["id"], "like", lib)
            changes.append((r["id"], r["mbid"], "like")); likes += 1
        elif os.path.exists(r["file"]):      # still in audition -> undecided, leave it
            undecided += 1
        else:                                # gone from both -> deleted -> dislike
            db.set_label(con, r["id"], "dislike", "")
            changes.append((r["id"], r["mbid"], "dislike")); dislikes += 1

    # reconcile: a 'like' whose library file you later deleted -> dislike + hate
    reconciled = 0
    for r in db.liked_with_files(con):
        if not os.path.exists(r["file"]):
            db.set_label(con, r["id"], "dislike", "")
            changes.append((r["id"], r["mbid"], "dislike")); reconciled += 1

    sent, skip = send_feedback(con, changes)
    con.commit()
    na = write_m3u("Audition", AUDITION)
    nl = write_m3u("Library", LIBRARY)

    ok(f"[green]{likes}[/] liked  ·  [yellow]{dislikes}[/] disliked  ·  "
       f"[dim]{undecided} still deciding[/]")
    if reconciled:
        info(f"reconciled {reconciled} removed-from-library → dislike")
    ok(f"feedback [green]{sent}[/] sent"
       + (f"  ·  [dim]{skip} skipped[/]" if skip else "")
       + f"  ·  library [bold]{nl}[/]  ·  audition [bold]{na}[/]")


if __name__ == "__main__":
    main()
