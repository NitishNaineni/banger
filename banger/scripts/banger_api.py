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


def _send_feedback(mbid, score):
    """Submit a recording-feedback score to ListenBrainz: 1=loved, -1=hated, 0=clear.
    Returns True if accepted, the string "net" if LB couldn't be reached (network/auth/
    rate-limit/server — retry the whole backlog later), or False if LB rejected THIS
    recording (bad/unknown mbid — skip it so it doesn't block the rest)."""
    token = _lb_token()
    if not token or not mbid:
        return False
    body = json.dumps({"recording_mbid": mbid, "score": score}).encode()
    req = urllib.request.Request(
        LB_FEEDBACK, data=body, method="POST",
        headers={"Authorization": f"Token {token}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=12)
        return True
    except Exception as e:
        # HTTPError has .code; 400/404 = this recording is bad -> skip it.
        # anything else (timeout, 401/429/5xx, no network) -> stop and retry later.
        return False if getattr(e, "code", None) in (400, 404) else "net"


def _flush_pending(con):
    """Reconcile every track's ListenBrainz feedback with its label, so love / hate /
    clear all reach LB eventually whether you're online or off.

    A row is out of sync when the score its label wants (like=1, dislike=-1, un-rated=0)
    differs from `lb_sent` (what's actually on LB). For such rows we resolve an MBID from
    the FLAC if the DB lacks one (embedded MusicBrainz id or ISRC — exact ids only), send
    the desired score, and record it. Stop on a network-level failure (retry the whole
    backlog later); skip a recording LB rejects so it can't block the rest."""
    dirty = False
    n = 0
    # candidates: anything rated, plus anything still believed to be on LB (needs a clear)
    rows = con.execute("SELECT id, mbid, label, file, lb_sent FROM tracks "
                       "WHERE label IN ('like','dislike') OR lb_sent IS NOT NULL").fetchall()
    for r in rows:
        desired = {"like": 1, "dislike": -1}.get(r["label"], 0)
        current = r["lb_sent"] if r["lb_sent"] is not None else 0
        if desired == current:
            continue                       # already in sync
        mbid = r["mbid"]
        if not mbid and r["file"]:
            mbid = _mbid_from_file(r["file"])
            if mbid:
                con.execute("UPDATE tracks SET mbid=? WHERE id=?", (mbid, r["id"]))
                dirty = True
        if not mbid:
            continue                       # unidentifiable for now — try again next flush
        res = _send_feedback(mbid, desired)
        if res is True:
            # 0 means "nothing on LB" -> store NULL so the row drops out of the candidates
            con.execute("UPDATE tracks SET lb_sent=? WHERE id=?",
                        (None if desired == 0 else desired, r["id"]))
            n += 1; dirty = True
        elif res == "net":
            break                          # can't reach LB — stop, retry whole backlog later
        # else (False): LB rejected this recording — leave it, don't block the rest
    if dirty:
        con.commit()
    return n


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
    # set ONLY the label; keep `file` as the audition path so basename lookups still work.
    # lb_sent is left untouched so the flush can reconcile the change (love/hate/clear)
    # against what's currently on LB — and retry until delivered, online or offline.
    con.execute("UPDATE tracks SET label=?, updated_at=datetime('now') WHERE id=?",
                (label, r["id"]))
    con.commit()
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
    mk = subprocess.run([sys.executable, os.path.join(SCRIPTS, "make_batch.py"), "--size", "100"],
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


def _resolve_deezer(url):
    """Follow a link.deezer.com short link to the real deezer.com URL."""
    import requests
    try:
        return requests.get(url, allow_redirects=True, timeout=15,
                            headers={"User-Agent": "Mozilla/5.0"}).url
    except Exception:
        return url


def _flac_tags(path):
    from mutagen.flac import FLAC
    try:
        a = FLAC(path)
        g = lambda k: (a.get(k) or [""])[0]
        return g("ARTIST"), g("TITLE"), g("ALBUM"), g("ISRC")
    except Exception:
        return "", "", "", ""


def _mbid_from_isrc(isrc):
    """Best-effort recording MBID from the ISRC, so the add can be loved on LB."""
    if not isrc:
        return ""
    import requests
    try:
        # the /isrc resource returns its linked recordings by default; passing
        # inc=recordings is REJECTED as invalid, so don't (that silently broke this).
        r = requests.get("https://musicbrainz.org/ws/2/isrc/" + isrc,
                        params={"fmt": "json"},
                        headers={"User-Agent": "banger/1.0 (g4music)"}, timeout=12).json()
        recs = r.get("recordings", [])
        return recs[0]["id"] if recs else ""
    except Exception:
        return ""


def _mbid_from_file(path):
    """Recording MBID for a FLAC: an embedded MusicBrainz id if present (precise),
    else resolved from the ISRC. Used to let hand-added tracks reach ListenBrainz.
    Only exact identifiers — never a fuzzy artist/title match, which could love the
    wrong recording."""
    from mutagen.flac import FLAC
    try:
        a = FLAC(path)
        for k in ("MUSICBRAINZ_TRACKID", "MUSICBRAINZ_RECORDINGID"):
            v = (a.get(k) or [""])[0]
            if v:
                return v
        return _mbid_from_isrc((a.get("ISRC") or [""])[0])
    except Exception:
        return ""


def cmd_add(url):
    # Resolve the (possibly shortened) Deezer link, download straight into the library
    # as a liked track, fetch its lyrics, and record it. Progress lines like cmd_refresh.
    import lyrics
    _line("progress", "Resolving link…")
    full = _resolve_deezer(url)
    if "deezer.com" not in full:
        _line("ok", False)
        _line("error", "That doesn't look like a Deezer link")
        return
    os.makedirs(LIBRARY, exist_ok=True)
    rip = os.path.join(SCRIPTS, "..", ".venv", "bin", "rip")
    rip = rip if os.path.exists(rip) else "rip"
    before = set(audio_files(LIBRARY))
    _line("progress", "Downloading…")
    try:
        subprocess.run([rip, "--no-db", "--folder", LIBRARY, "url", full],
                       capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        _line("ok", False)
        _line("error", "Download timed out")
        return
    new = sorted(set(audio_files(LIBRARY)) - before)
    if not new:
        _line("ok", False)
        _line("error", "Nothing downloaded — track may be unavailable on Deezer")
        return
    con = db.connect()
    first = ""
    for f in new:
        artist, title, album, isrc = _flac_tags(f)
        desc = f"{artist} - {title}".strip(" -")
        _line("progress", "Tagging " + desc)
        try:
            lyrics.process(f, artist, title, allow_slow=True)
        except Exception:
            pass
        db.add_manual(con, artist, title, album, "", f, _mbid_from_file(f))
        _line("path", f)
        first = first or desc
    _flush_pending(con)   # love them on LB (resolves any missing mbid); retried later if offline
    con.commit()
    con.close()
    write_m3u("Library", LIBRARY)
    _line("ok", True)
    _line("added", len(new))
    _line("name", first)


def cmd_sync():
    # Reconcile the library folder against the DB: any FLAC sitting in ~/Music/library
    # that isn't a known liked track yet is "officially imported" IN PLACE — lyrics
    # fetched + embedded if missing, recorded as liked. Lets the user just copy files
    # into the folder (file manager / Syncthing) and have the app pick them up.
    import lyrics
    from mutagen.flac import FLAC
    con = db.connect()
    known = {os.path.basename(r["file"]).lower()
             for r in con.execute("SELECT file FROM tracks WHERE label='like' AND file != ''")}
    imported = 0
    for f in audio_files(LIBRARY):
        if os.path.basename(f).lower() in known:
            continue
        artist, title, album, isrc = _flac_tags(f)
        try:
            if not FLAC(f).get("LYRICS"):   # keep the file's own lyrics if it has them
                lyrics.process(f, artist, title)
        except Exception:
            pass
        db.add_manual(con, artist, title, album, "", f, _mbid_from_file(f))
        _line("path", f)
        imported += 1
    if imported:
        _flush_pending(con)   # love them on LB (resolves missing mbids); retried later if offline
        write_m3u("Library", LIBRARY)
    con.commit()
    con.close()
    _line("ok", True)
    _line("imported", imported)


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
    p_add = sub.add_parser("add")
    p_add.add_argument("--url", required=True)
    sub.add_parser("sync")
    args = ap.parse_args()

    if args.cmd == "refresh":
        cmd_refresh()
        return
    if args.cmd == "add":
        cmd_add(args.url)
        return
    if args.cmd == "sync":
        cmd_sync()
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
