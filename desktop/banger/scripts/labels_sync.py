#!/usr/bin/env python3
"""
labels_sync.py — cross-device like/dislike sync as a CRDT carried over Syncthing.

Each device appends its decisions to its OWN append-only log under the Syncthing-synced
library folder:  ~/Music/library/.banger/labels-<device>.jsonl
No two devices ever write the same file, so Syncthing never hits a conflict. Every device
merges all logs by last-writer-wins (newest timestamp; device-id breaks ties) to get the
agreed label per track. The desktop reconciles the merge into discovery.db + ListenBrainz;
the phone appends its taps here too and reads the merge to show current state.

Track key = "<artist>|<title>" lowercased — the identity both the desktop DB and the phone
(reading FLAC tags) can compute without a resolved MBID. Hidden dotfolder, so the media
scanners (desktop + Auxio) ignore it; it rides the existing music-library Syncthing folder.
"""
import json
import os
import time
import uuid

from _paths import DATA, LIBRARY

SYNC_DIR = os.path.join(LIBRARY, ".banger")
_ID_FILE = os.path.join(DATA, "device_id")   # stable per-device id, NOT synced


def device_id():
    try:
        return open(_ID_FILE, encoding="utf-8").read().strip()
    except Exception:
        did = "pc-" + uuid.uuid4().hex[:8]
        os.makedirs(DATA, exist_ok=True)
        with open(_ID_FILE, "w", encoding="utf-8") as f:
            f.write(did)
        return did


def key_for(artist, title):
    return f"{(artist or '').strip().lower()}|{(title or '').strip().lower()}"


def record(artist, title, label):
    """Append this device's decision for a track to its own append-only log."""
    os.makedirs(SYNC_DIR, exist_ok=True)
    entry = {"k": key_for(artist, title), "l": label or "none",
             "t": int(time.time() * 1000), "d": device_id()}
    path = os.path.join(SYNC_DIR, f"labels-{device_id()}.jsonl")
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def merge():
    """Merge every device log by last-writer-wins -> {key: (label, ts, dev)}."""
    best = {}
    if not os.path.isdir(SYNC_DIR):
        return best
    for fn in sorted(os.listdir(SYNC_DIR)):
        if not (fn.startswith("labels-") and fn.endswith(".jsonl")):
            continue
        try:
            with open(os.path.join(SYNC_DIR, fn), encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    e = json.loads(line)
                    k, cur = e["k"], best.get(e["k"])
                    if cur is None or (e["t"], e["d"]) > (cur[1], cur[2]):
                        best[k] = (e["l"], e["t"], e["d"])
        except Exception:
            continue
    return best
