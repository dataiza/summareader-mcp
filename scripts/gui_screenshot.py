#!/usr/bin/env python3
"""Regenerate `docs/gui.png`, the picture of the desktop window.

The same discipline as scripts/screenshot.py beside it, and the same library:
a screenshot taken by hand is right once and quietly wrong for every change
after. This seeds the small library that script describes, opens the real
window against it, and photographs it — because Tk, unlike Textual, has no way
to render itself anywhere but onto a display.

So this one does need a display, and says so rather than producing nothing:

    DISPLAY=:0 uv run python scripts/gui_screenshot.py

XDG_CONFIG_HOME is pointed at a temporary directory, so "Start at login" reads
false whatever the machine taking the picture happens to have installed — and
so that running this can never write a unit into somebody's real config.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from screenshot import BODY, RECORDS  # noqa: E402  — the library both pictures use

from summareader_mcp.config import Config  # noqa: E402
from summareader_mcp.store import open_store  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "docs" / "gui.png"


def shoot() -> int:
    if not os.environ.get("DISPLAY"):
        print("no DISPLAY: this one is a photograph, not a render.", file=sys.stderr)
        return 1
    if not shutil.which("import"):
        print("ImageMagick's `import` is what takes it.", file=sys.stderr)
        return 1

    import tkinter as tk
    from tkinter import ttk

    from summareader_mcp.gui import Window

    with tempfile.TemporaryDirectory() as tmp:
        os.environ["XDG_CONFIG_HOME"] = str(Path(tmp) / "config")
        cache = Path(tmp) / "cache"
        store = open_store(cache / "library.sqlite")
        try:
            store.apply_all(RECORDS)
            store.store_body("a1", BODY)
            store.set_setting("sync.cursor", "418")

            # A real mirror rather than a `--library` one: that is the window
            # with all its controls live, which is the state worth documenting.
            config = Config(
                server="https://sync.example.com",
                token="device-token",
                master_key=b"\0" * 32,
                # Where a real installation keeps it, rather than the temporary
                # directory this is actually reading: the picture is of the
                # program, and nobody's home directory belongs in it. Only the
                # store already open above is read from, so this path is
                # displayed and never opened.
                cache_dir=Path("/home/you/.cache/summareader-mcp"),
                name="MCP mirror",
                bearer_token="set",
            )
            # Every worker inline, so the picture is of a window that has
            # finished loading rather than of one two seconds into doing so.
            Window._off_thread = (
                lambda self, work, done=None: self._finish(work(), done)
            )

            root = tk.Tk()
            # Out of the window manager's hands: a tiling one gives this the
            # whole screen, and a screenshot of a window stretched to 3840
            # pixels documents the desktop rather than the program.
            root.overrideredirect(True)
            root.geometry("820x700+80+80")
            Window(
                root, tk, ttk, config,
                Path("/home/you/.config/summareader-mcp/summareader-mcp.json"),
                store, "127.0.0.1", 8100,
            )
            root.update()
            root.update_idletasks()

            OUT.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["import", "-window", hex(root.winfo_id()), str(OUT)], check=True
            )
            root.destroy()
        finally:
            store.close()
    print(OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(shoot())
