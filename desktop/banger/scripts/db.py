"""
db.py — single SQLite store for all pipeline state.

One file (data/discovery.db) holds every track through its lifecycle and the
batches that served them. Replaces the old batch_*.csv / labels.csv files.

  batches: number, mode, created_at, downloaded_at
  tracks:  mbid, artist, title, album, batch, deezer_id, file, label, feedback

A track is deduped by recording MBID (or artist|title when it has none), so
nothing is ever recommended twice.
"""
import os, sqlite3
from _paths import DATA

DB_PATH = os.environ.get("DISCOVERY_DB", os.path.join(DATA, "discovery.db"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS batches (
    number        INTEGER PRIMARY KEY,
    mode          TEXT,
    created_at    TEXT DEFAULT (datetime('now')),
    downloaded_at TEXT
);
CREATE TABLE IF NOT EXISTS tracks (
    id         INTEGER PRIMARY KEY,
    mbid       TEXT DEFAULT '',
    artist     TEXT DEFAULT '',
    title      TEXT DEFAULT '',
    album      TEXT DEFAULT '',
    batch      INTEGER,
    deezer_id  TEXT DEFAULT '',
    file       TEXT DEFAULT '',
    label      TEXT,                       -- NULL until auditioned
    feedback   INTEGER DEFAULT 0,          -- 1 once love/hate sent to ListenBrainz
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ix_track_key
    ON tracks(COALESCE(NULLIF(mbid,''), artist || '|' || title));
CREATE INDEX IF NOT EXISTS ix_track_batch ON tracks(batch);
CREATE INDEX IF NOT EXISTS ix_track_label ON tracks(label);
CREATE TABLE IF NOT EXISTS submitted_listens (   -- phone listens already sent to ListenBrainz
    ts     INTEGER NOT NULL,
    device TEXT NOT NULL,
    PRIMARY KEY (ts, device)
);
"""


def connect():
    os.makedirs(DATA, exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    # lb_sent = the score currently reflected on ListenBrainz (1 loved / -1 hated /
    # NULL nothing). The feedback flusher reconciles the desired score (from `label`)
    # against this, so love/hate/clear all retry until delivered. Migrate older DBs:
    # rows already delivered (feedback=1) start in sync with their label's score.
    cols = {r[1] for r in con.execute("PRAGMA table_info(tracks)")}
    if "lb_sent" not in cols:
        con.execute("ALTER TABLE tracks ADD COLUMN lb_sent INTEGER")
        con.execute("UPDATE tracks SET lb_sent = CASE label WHEN 'like' THEN 1 "
                    "WHEN 'dislike' THEN -1 ELSE NULL END WHERE feedback = 1")
        con.commit()
    return con


# ---- batches ----------------------------------------------------------------
def new_batch(con, mode):
    n = con.execute("SELECT COALESCE(MAX(number), 0) FROM batches").fetchone()[0] + 1
    con.execute("INSERT INTO batches(number, mode) VALUES (?, ?)", (n, mode))
    return n


def latest_batch(con):
    return con.execute(
        "SELECT number, downloaded_at FROM batches ORDER BY number DESC LIMIT 1").fetchone()


def mark_downloaded(con, n):
    con.execute("UPDATE batches SET downloaded_at = datetime('now') WHERE number = ?", (n,))


# ---- tracks -----------------------------------------------------------------
def add_candidate(con, batch, t):
    con.execute(
        "INSERT OR IGNORE INTO tracks(mbid, artist, title, album, batch) VALUES (?,?,?,?,?)",
        (t.get("mbid", ""), t.get("artist", ""), t.get("title", ""), t.get("album", ""), batch))


def seen_mbids(con):
    return {r[0] for r in con.execute("SELECT mbid FROM tracks WHERE mbid != ''")}


def liked_artists(con):
    return [r[0] for r in con.execute(
        "SELECT artist FROM tracks WHERE label='like' AND artist != '' "
        "GROUP BY artist ORDER BY COUNT(*) DESC")]


def batch_tracks(con, batch, downloaded_only=False):
    q = "SELECT * FROM tracks WHERE batch = ?"
    if downloaded_only:
        q += " AND file != ''"
    return con.execute(q, (batch,)).fetchall()


def set_download(con, track_id, deezer_id, file):
    con.execute("UPDATE tracks SET deezer_id=?, file=?, updated_at=datetime('now') WHERE id=?",
                (deezer_id, file, track_id))


def set_label(con, track_id, label, file):
    con.execute("UPDATE tracks SET label=?, file=?, feedback=0, updated_at=datetime('now') "
                "WHERE id=?", (label, file, track_id))


def liked_with_files(con):
    return con.execute("SELECT * FROM tracks WHERE label='like' AND file != ''").fetchall()


def add_manual(con, artist, title, album, deezer_id, file, mbid):
    """Record a track added by hand (Deezer link) straight into the library as liked."""
    con.execute(
        "INSERT OR IGNORE INTO tracks(mbid, artist, title, album, deezer_id, file, label) "
        "VALUES (?,?,?,?,?,?, 'like')",
        (mbid, artist, title, album, deezer_id, file))
    con.execute(
        "UPDATE tracks SET label='like', file=?, deezer_id=?, feedback=0, "
        "updated_at=datetime('now') "
        "WHERE COALESCE(NULLIF(mbid,''), artist || '|' || title) "
        "    = COALESCE(NULLIF(?,''), ? || '|' || ?)",
        (file, deezer_id, mbid, artist, title))
