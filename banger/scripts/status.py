#!/usr/bin/env python3
"""
status.py — a quick, pretty summary of pipeline state from the DB.

    uv run python scripts/status.py
"""
import db
from _paths import AUDITION, audio_files
from _ui import console, header
from rich.table import Table
from rich.padding import Padding


def kv(rows):
    """A borderless, auto-aligned key/value grid, indented to the gutter."""
    g = Table.grid(padding=(0, 3))
    g.add_column(style="dim", justify="right")
    g.add_column()
    for k, v in rows:
        g.add_row(k, v)
    console.print(Padding(g, (0, 0, 0, 2)))


def main():
    con = db.connect()
    header("Music Discovery · status")

    n_batches = con.execute("SELECT COUNT(*) FROM batches").fetchone()[0]
    latest = con.execute(
        "SELECT number, downloaded_at FROM batches ORDER BY number DESC LIMIT 1").fetchone()
    total = con.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
    like = con.execute("SELECT COUNT(*) FROM tracks WHERE label='like'").fetchone()[0]
    dislike = con.execute("SELECT COUNT(*) FROM tracks WHERE label='dislike'").fetchone()[0]
    pending = total - like - dislike
    aud = len(audio_files(AUDITION))
    top = con.execute(
        "SELECT artist, COUNT(*) c FROM tracks WHERE label='like' AND artist != '' "
        "GROUP BY artist ORDER BY c DESC LIMIT 6").fetchall()

    rows = []
    if latest:
        st = "[green]downloaded[/]" if latest["downloaded_at"] else "[yellow]pending download[/]"
        rows.append(("batches", f"[bold]{n_batches}[/]   latest [bold]#{latest['number']}[/]   {st}"))
    else:
        rows.append(("batches", "[dim]none yet — run cycle to start[/]"))
    rows.append(("tracks",
                 f"[bold]{total}[/] seen   {aud} in audition   "
                 f"[green]{like}[/] kept   [yellow]{dislike}[/] disliked   [dim]{pending} pending[/]"))
    if top:
        rows.append(("taste", "   ".join(f"{r['artist']} [dim]{r['c']}[/]" for r in top)))

    kv(rows)
    console.print()


if __name__ == "__main__":
    main()
