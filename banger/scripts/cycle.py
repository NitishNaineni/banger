#!/usr/bin/env python3
"""
cycle.py — one command for a whole turn of the loop.

Reads pipeline state from the DB:
  - no batches yet            -> generate one, download it (populate Audition)
  - latest batch downloaded   -> process culls, generate next batch, download it
  - latest batch not downloaded (first run) -> just download it

  uv run python scripts/cycle.py             # run the loop turn
  uv run python scripts/cycle.py --dry-run   # show the steps, change nothing
"""
import argparse, os, subprocess, sys
import db
from _paths import AUDITION, audio_files
from _ui import header, phase, info, done

SCRIPTS = os.path.dirname(__file__)


def latest():
    c = db.connect()
    row = db.latest_batch(c)
    c.close()
    return row


def run(script, *args, dry):
    if dry:
        info("would run: " + " ".join(["scripts/" + script] + [str(x) for x in args]))
        return
    subprocess.run([sys.executable, os.path.join(SCRIPTS, script), *map(str, args)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    dry = ap.parse_args().dry_run

    header("Music Discovery")

    row = latest()
    if row is None:
        phase("Generating first batch")
        run("make_batch.py", dry=dry)
        row = latest()
    n = row["number"] if row else 1
    downloaded = bool(row and row["downloaded_at"])

    if downloaded:
        phase("Processing your sort · library = like, deleted = dislike")
        run("capture_labels.py", dry=dry)
        phase("Next batch · derived from your taste")
        run("make_batch.py", dry=dry)
        n = (latest()["number"] if not dry else n + 1)
    else:
        phase(f"First run · batch #{n} → populating Audition")

    phase(f"Downloading · batch #{n} → Audition")
    run("download_batch.py", n, dry=dry)

    if dry:
        info("dry run · nothing changed")
    else:
        count = len(audio_files(AUDITION))
        done(f"Audition [bold]{count}[/] tracks · open in G4Music, cull, run cycle again")


if __name__ == "__main__":
    main()
