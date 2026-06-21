"""Shared rich console + tasteful, concise output helpers.

Design: a quiet two-space gutter, one accent colour, nested results under steps.
No full-width rules, no scattered boxes.

    ♫  Music Discovery

    ▸ Processing audition · batch #3
      ✓ 7 kept → library · 13 deleted
    ▸ Downloading · batch #4 → Audition
      ✓ downloaded 94 · 4 no match

    ✓ Done · Audition 94 tracks
"""
from rich.console import Console
from rich.progress import (Progress, SpinnerColumn, BarColumn, TextColumn,
                           MofNCompleteColumn)

console = Console()

ACCENT = "bright_cyan"


def header(text):
    console.print(f"\n  [bold bright_magenta]♫[/]  [bold]{text}[/]\n")


def phase(title):
    console.print(f"  [{ACCENT}]▸[/] [bold]{title}[/]")


def ok(msg):    console.print(f"    [green]✓[/] {msg}")
def warn(msg):  console.print(f"    [yellow]![/] {msg}")
def err(msg):   console.print(f"    [red]✗[/] {msg}")
def info(msg):  console.print(f"    [dim]{msg}[/]")
def line(msg):  console.print(f"    {msg}")   # indented, keeps its own colours


def done(msg):  console.print(f"\n  [bold green]✓[/] {msg}\n")


def download_progress():
    """Compact, indented live progress bar for the download phase."""
    return Progress(
        TextColumn("   "),
        SpinnerColumn(style=ACCENT),
        BarColumn(bar_width=22, complete_style="green", finished_style="green"),
        MofNCompleteColumn(),
        TextColumn("[dim]{task.description}"),
        console=console,
    )
