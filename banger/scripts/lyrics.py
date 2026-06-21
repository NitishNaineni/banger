#!/usr/bin/env python3
"""
lyrics.py — best-available synced lyrics for a track, written as an .lrc sidecar.

We download from Deezer, which has NO word-level lyrics. The reliable, NON-rate-
limited way to get true per-word ("karaoke") timing — important because a refresh
fetches lyrics for ~100 tracks at once — is to query the big karaoke catalogs that
publish word-by-word data and don't throttle the way Musixmatch's anon token does:

  word  : Kugou (krc) -> NetEase (yrc)   — per-word timing, converted to enhanced LRC
  line  : LRCLIB / NetEase (lrc)         — one timestamp per line
  plain : LRCLIB plain                   — no timestamps
  none  : nothing found

Enhanced-LRC output (what the desktop player parses for karaoke):

    [00:07.14]<00:07.14>One <00:07.50>look <00:07.80>give 'em whiplash

The `.lrc` sidecar (same basename) is what the player reads and what Syncthing
carries to the phone; the FLAC LYRICS tag is set too so the file is self-contained.
"""
import base64
import os
import re
import threading
import zlib

import requests
from mutagen.flac import FLAC

WORD, LINE, PLAIN, NONE = "word", "line", "plain", "none"

_UA = {"User-Agent": "Mozilla/5.0"}
_TIMEOUT = 12
# Kugou krc XOR key (well-known constant used by every krc decoder).
_KUGOU_KEY = bytes(
    [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
     0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69])

_HAS_WORD = re.compile(r"<\d\d:\d\d")
_HAS_LINE = re.compile(r"\[\d\d:\d\d")
# Karaoke catalogs prefix songwriter/producer credits as timed "lyric" lines —
# drop them so the karaoke view starts on the actual first sung line. QQ Music uses
# single-char markers with a colon (词：/曲：/编曲：), so match those too.
_CREDIT = re.compile(
    r"(作?词\s*[:：]|作?曲\s*[:：]|编\s*曲|制作|出品|监制|配唱|和声|录音|混音|母带|"
    r"produced|written|composed|lyrics?\s+by|music\s+by|arrang|mixing|master(ed|ing))",
    re.IGNORECASE)

_TAGS = re.compile(r"\[[^\]]*\]|<[^>]*>")   # strip [..] and <..> to get a line's plain text


def _is_credit(text):
    return bool(_CREDIT.search(text))


def _strip_credits(enh):
    """Drop the leading metadata block QQ/Kugou prepend — the 'Title - Artist' line and
    the 词/曲/编曲 credit lines — so the lyrics start on the first sung line."""
    if not enh:
        return enh
    lines = enh.splitlines()
    i = 0
    while i < len(lines):
        plain = _TAGS.sub("", lines[i]).strip()
        nxt = _TAGS.sub("", lines[i + 1]).strip() if i + 1 < len(lines) else ""
        # a 'Title - Artist' line only counts as a credit if a real credit follows it
        title = i == 0 and " - " in plain and _is_credit(nxt)
        if _is_credit(plain) or title:
            i += 1
        else:
            break
    return "\n".join(lines[i:]) if i < len(lines) else enh


# ── time / format helpers ────────────────────────────────────────────────────

def _ms_to_lrc(ms):
    """milliseconds -> 'mm:ss.xx' (centiseconds)."""
    cs = int(round(ms / 10.0))
    return f"{cs // 6000:02d}:{(cs % 6000) // 100:02d}.{cs % 100:02d}"


def _krc_to_enhanced(krc):
    """Kugou krc -> enhanced LRC. krc word offsets are RELATIVE to the line start."""
    out = []
    for line in krc.splitlines():
        m = re.match(r"^\[(\d+),(\d+)\](.*)$", line)   # skip [ti:]/[ar:]/… meta tags
        if not m:
            continue
        line_start = int(m.group(1))
        words = re.findall(r"<(\d+),(\d+),\d+>([^<]*)", m.group(3))
        if not words:
            continue
        buf = f"[{_ms_to_lrc(line_start)}]"
        for off, _dur, txt in words:
            buf += f"<{_ms_to_lrc(line_start + int(off))}>{txt}"
        out.append(buf)
    return "\n".join(out) if out else None


def _yrc_to_enhanced(yrc):
    """NetEase yrc -> enhanced LRC. yrc word start times are ABSOLUTE milliseconds."""
    out = []
    for line in yrc.splitlines():
        line = line.strip()
        if not line or line.startswith("{"):   # skip the JSON credits header line
            continue
        m = re.match(r"^\[(\d+),(\d+)\](.*)$", line)
        if not m:
            continue
        words = re.findall(r"\((\d+),(\d+),\d+\)([^(]*)", m.group(3))
        if not words:
            continue
        buf = f"[{_ms_to_lrc(int(m.group(1)))}]"
        for start, _dur, txt in words:
            buf += f"<{_ms_to_lrc(int(start))}>{txt}"
        out.append(buf)
    return "\n".join(out) if out else None


# ── providers (all free, no auth, not aggressively rate-limited) ──────────────

def _kugou(query):
    """Kugou: search -> krc candidate -> download + XOR/zlib decrypt. Returns krc text."""
    try:
        r = requests.get("https://mobilecdn.kugou.com/api/v3/search/song",
                         params={"keyword": query, "page": 1, "pagesize": 5, "format": "json"},
                         headers=_UA, timeout=_TIMEOUT).json()
        info = r.get("data", {}).get("info", [])
        if not info:
            return None
        song = info[0]
        s = requests.get("https://krcs.kugou.com/search",
                        params={"ver": 1, "man": "yes", "client": "mobi",
                                "hash": song["hash"], "duration": song.get("duration", 0) * 1000},
                        headers=_UA, timeout=_TIMEOUT).json()
        cands = s.get("candidates", [])
        if not cands:
            return None
        c = cands[0]
        d = requests.get("https://lyrics.kugou.com/download",
                        params={"ver": 1, "client": "pc", "id": c["id"],
                                "accesskey": c["accesskey"], "fmt": "krc", "charset": "utf8"},
                        headers=_UA, timeout=_TIMEOUT).json()
        content = d.get("content")
        if not content:
            return None
        raw = base64.b64decode(content)[4:]   # strip 'krc1' magic
        dec = bytes(b ^ _KUGOU_KEY[i % 16] for i, b in enumerate(raw))
        return zlib.decompress(dec).decode("utf-8", "ignore")
    except Exception:
        return None


def _netease(query):
    """NetEase: search -> lyric (yrc word-level + lrc line-level). Returns (yrc, lrc)."""
    try:
        r = requests.get("https://music.163.com/api/search/get",
                        params={"s": query, "type": 1, "limit": 3},
                        headers={**_UA, "Referer": "https://music.163.com/"}, timeout=_TIMEOUT).json()
        songs = r.get("result", {}).get("songs", [])
        if not songs:
            return None, None
        ly = requests.get("https://music.163.com/api/song/lyric",
                         params={"id": songs[0]["id"], "lv": 1, "yv": 1},
                         headers={**_UA, "Referer": "https://music.163.com/"}, timeout=_TIMEOUT).json()
        return (ly.get("yrc", {}).get("lyric") or None,
                ly.get("lrc", {}).get("lyric") or None)
    except Exception:
        return None, None


def _lrclib(query):
    """LRCLIB: returns (synced_lrc, plain). Shorter timeout — it's only a line-level
    fallback and can be slow, so don't let it stall the batch."""
    try:
        r = requests.get("https://lrclib.net/api/search",
                        params={"q": query}, headers=_UA, timeout=7).json()
        if not r:
            return None, None
        t = r[0]
        return (t.get("syncedLyrics") or None), (t.get("plainLyrics") or None)
    except Exception:
        return None, None


# QQ Music word-by-word QRC (decrypted by qqmusic-api-python's buggy-DES). The client
# is async; we keep a PER-THREAD event loop + client (the first call on a thread pays
# the session setup, the rest are ~1s) so the download pool can fetch lyrics in
# parallel. Not rate-limited like Musixmatch.
_qq_tls = threading.local()


async def _qq_fetch(query):
    from qqmusic_api import Client
    from qqmusic_api.modules.search import SearchType
    client = getattr(_qq_tls, "client", None)
    if client is None:
        client = Client()
        _qq_tls.client = client
    res = await client.search.search_by_type(query, search_type=SearchType.SONG, num=1)
    songs = res.model_dump().get("song") or []
    if not songs:
        return None
    resp = await client.lyric.get_lyric(songs[0]["mid"], qrc=True)
    return resp.decrypt().lyric or None


def _qqmusic(query):
    """QQ Music QRC -> enhanced LRC. QRC word timing is <abs_start,dur> AFTER each word."""
    try:
        loop = getattr(_qq_tls, "loop", None)
        if loop is None:
            import asyncio
            loop = asyncio.new_event_loop()
            _qq_tls.loop = loop
        xml = loop.run_until_complete(_qq_fetch(query))
    except Exception:
        return None
    if not xml:
        return None
    m = re.search(r'LyricContent="(.*)"\s*/>', xml, re.DOTALL)
    if not m:
        return None
    out = []
    for line in m.group(1).splitlines():
        lm = re.match(r"^\[(\d+),(\d+)\](.*)$", line)   # skip [ti:]/[ar:]/… meta
        if not lm:
            continue
        words = re.findall(r"([^(]*)\((\d+),(\d+)\)", lm.group(3))
        if not words:
            continue
        buf = f"[{_ms_to_lrc(int(lm.group(1)))}]"
        for text, start, _dur in words:
            buf += f"<{_ms_to_lrc(int(start))}>{text}"
        out.append(buf)
    return "\n".join(out) if out else None


def _musixmatch(query):
    """Musixmatch richsync (word-level). Its anon token rate-limits hard, so this is
    used ONLY for single manual adds — never the bulk refresh."""
    try:
        from syncedlyrics.providers.musixmatch import Musixmatch
        r = Musixmatch(enhanced=True).get_lrc(query)
        s = r.synced if r else None
        return s if (s and _HAS_WORD.search(s)) else None
    except Exception:
        return None


# ── orchestration ─────────────────────────────────────────────────────────────

def fetch(artist, title, allow_slow=False):
    """Return (kind, synced_text_or_None, plain_text_or_None), best tier first.

    allow_slow=True (single manual adds only) also tries Musixmatch, whose token
    rate-limits and so must stay out of the 100-song bulk refresh.
    """
    query = f"{title} {artist}".strip()

    # 1) word-level — QQ Music, then Kugou, then NetEase (all unthrottled); Musixmatch
    #    last and only when allowed. Different catalogs, so trying several maximises it.
    word = _qqmusic(query)
    if not word:
        krc = _kugou(query)
        word = _krc_to_enhanced(krc) if krc else None
    ne_lrc = None
    if not word:
        yrc, ne_lrc = _netease(query)
        word = _yrc_to_enhanced(yrc) if yrc else None
    if not word and allow_slow:
        word = _musixmatch(query)
    if word:
        # we have synced word-level lyrics — no need for a (sometimes slow) LRCLIB
        # round-trip just to fetch plain text we won't use.
        return WORD, _strip_credits(word), None

    # 2) line-level — LRCLIB, then NetEase plain-lrc.
    lr_synced, lr_plain = _lrclib(query)
    if lr_synced:
        return LINE, lr_synced, lr_plain
    if ne_lrc is None:
        _, ne_lrc = _netease(query)
    if ne_lrc and _HAS_LINE.search(ne_lrc):
        return LINE, ne_lrc, lr_plain

    # 3) plain text only.
    if lr_plain:
        return PLAIN, None, lr_plain
    return NONE, None, None


def lrc_path(track_path):
    return os.path.splitext(track_path)[0] + ".lrc"


def write_sidecar(track_path, synced, plain):
    body = synced or plain
    if not body:
        return None
    path = lrc_path(track_path)
    with open(path, "w", encoding="utf-8") as f:
        f.write(body if body.endswith("\n") else body + "\n")
    return path


def embed(track_path, synced, plain):
    body = synced or plain
    if not body or not track_path.lower().endswith(".flac"):
        return False
    try:
        audio = FLAC(track_path)
        audio["LYRICS"] = body
        if synced and _HAS_LINE.search(synced):
            audio["SYNCEDLYRICS"] = synced
        audio.save()
        return True
    except Exception:
        return False


def process(track_path, artist, title, allow_slow=False):
    """Fetch + embed lyrics into the FLAC (no .lrc sidecar). Returns the kind obtained."""
    kind, synced, plain = fetch(artist, title, allow_slow=allow_slow)
    if kind != NONE:
        embed(track_path, synced, plain)
    return kind


def _parse_basename(path):
    """'01. Artist - Title.flac' -> ('Artist', 'Title'). Fallback: ('', stem)."""
    stem = os.path.splitext(os.path.basename(path))[0]
    m = re.match(r"^\s*\d+\.\s*(.+?)\s*-\s*(.+)$", stem)
    return (m.group(1), m.group(2)) if m else ("", stem)


def main():
    """CLI: backfill a folder/files in place. Prints '<kind>\\t<basename>' + SUMMARY."""
    import sys
    import glob

    args = sys.argv[1:]
    if not args:
        print("usage: lyrics.py <dir|file> ...", file=sys.stderr)
        sys.exit(2)
    files = []
    for a in args:
        files += sorted(glob.glob(os.path.join(a, "*.flac"))) if os.path.isdir(a) else [a]

    from concurrent.futures import ThreadPoolExecutor

    def one(f):
        artist, title = _parse_basename(f)
        kind = process(f, artist, title)
        print(f"{kind}\t{os.path.basename(f)}", flush=True)
        return kind

    counts = {WORD: 0, LINE: 0, PLAIN: 0, NONE: 0}
    with ThreadPoolExecutor(max_workers=6) as pool:
        for kind in pool.map(one, files):
            counts[kind] += 1
    print(f"SUMMARY\tword={counts[WORD]}\tline={counts[LINE]}\t"
          f"plain={counts[PLAIN]}\tnone={counts[NONE]}\ttotal={len(files)}", flush=True)


if __name__ == "__main__":
    main()
