"""Shared paths + config/playlist helpers for the discovery pipeline.

Music lives under ~/Music so it's visible in the player (and synced via Syncthing):
    ~/Music/audition/   tracks currently under review  (current batch)
    ~/Music/library/    tracks you liked               (a copy of each liked track)
    ~/Music/Playlists/  M3U playlists the apps display: Audition.m3u, Library.m3u

State and secrets live OUTSIDE the source tree (XDG dirs), so the bundled copy of
this pipeline inside the app can be rebuilt/updated without touching user data:
    $BANGER_DATA   (default ~/.local/share/banger)            discovery.db
    $BANGER_CONFIG (default ~/.config/banger/config.toml)     Deezer ARL + LB token
"""
import os
import re

HOME = os.path.expanduser("~")

MUSIC = os.path.expanduser("~/Music")
AUDITION = os.path.join(MUSIC, "audition")
LIBRARY = os.path.join(MUSIC, "library")
PLAYLISTS = os.path.join(MUSIC, "Playlists")

# State dir (DB). Override with BANGER_DATA; else XDG data home.
DATA = os.environ.get("BANGER_DATA") or os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "banger")

# Config file (secrets). Override with BANGER_CONFIG; else XDG config home.
CONFIG = os.environ.get("BANGER_CONFIG") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "banger", "config.toml")

AUDIO_EXT = (".flac", ".mp3", ".m4a", ".ogg", ".opus")


def norm(s: str) -> str:
    """Lowercase + strip everything but [a-z0-9], for fuzzy artist/title matching."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def load_config() -> dict:
    """Parse the user's config.toml (Deezer ARL, ListenBrainz token). {} if missing."""
    try:
        import tomllib
        with open(CONFIG, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def audio_files(folder: str) -> list:
    if not os.path.isdir(folder):
        return []
    out = []
    for root, _, files in os.walk(folder):
        for fn in sorted(files):
            if fn.lower().endswith(AUDIO_EXT):
                out.append(os.path.join(root, fn))
    return out


def write_m3u(name: str, folder: str) -> int:
    """(Re)generate ~/Music/Playlists/<name>.m3u from a folder's audio files."""
    os.makedirs(PLAYLISTS, exist_ok=True)
    tracks = audio_files(folder)
    path = os.path.join(PLAYLISTS, f"{name}.m3u")
    with open(path, "w") as f:
        f.write("#EXTM3U\n")
        for t in tracks:
            f.write(t + "\n")
    return len(tracks)
