#!/usr/bin/env python3
"""Regenerate `docs/tui.svg`, the picture of the terminal interface in the README.

A screenshot nobody can reproduce goes stale silently, so this is a script
rather than something done by hand once. It seeds a small library through the
real store and the real records — the same path the puller writes down — and
paints the real app against it headlessly, so what ends up in the README is the
program rather than a drawing of it.

    uv run python scripts/screenshot.py
"""

from __future__ import annotations

import asyncio
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from summareader_mcp.config import Config  # noqa: E402
from summareader_mcp.protocol.records import LogOp, LogRecord  # noqa: E402
from summareader_mcp.store import open_store  # noqa: E402
from summareader_mcp.tui import LibraryUI  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "docs" / "tui.svg"


def item(id: str, title: str, feed: str, published: str, read: bool = False):
    return LogRecord(
        op=LogOp.ITEM,
        id=id,
        data={
            "url": f"https://example.com/{id}",
            "title": title,
            "published": published,
            "fetched": published,
            "channels": [
                {"id": feed.lower(), "kind": "rss", "title": feed,
                 "url": f"https://{feed.lower().replace(' ', '')}.example/feed"},
            ],
            "read": read,
        },
    )


def summary(id: str, tldr: str, points: list[str], created: str):
    return LogRecord(
        op=LogOp.SUMMARY,
        id=id,
        data={
            "model": "qwen2.5:14b",
            "created": created,
            "text": __import__("json").dumps({"tldr": tldr, "points": points}),
        },
    )


# A small library that looks like one: a few feeds, a month of dates, most of
# it summarized and some of it read.
RECORDS = [
    item("a1", "What the borrow checker actually proves",
         "Lime", "2026-08-11T08:20:00.000Z"),
    summary("a1",
            "Ownership is a proof about aliasing, not about memory: the "
            "allocator is a consequence of the rule, never its point.",
            ["A borrow is a claim that nobody else is writing right now.",
             "Lifetimes annotate the claim; they do not create it.",
             "`unsafe` suspends the proof, not the rules it was proving."],
            "2026-08-11T08:41:00.000Z"),
    item("a2", "SQLite as an application file format",
         "Lime", "2026-08-09T17:05:00.000Z", read=True),
    summary("a2",
            "A single file with transactions beats a directory of formats "
            "nobody agreed on, and survives the crash halfway through a save.",
            ["Atomic writes come free; a hand-rolled format has to earn them.",
             "One file is one thing to copy, back up and hand over."],
            "2026-08-09T17:22:00.000Z"),
    item("a3", "Why your backups are not backups until you restore one",
         "The Morning Paper", "2026-08-08T06:00:00.000Z"),
    summary("a3",
            "An untested backup is a belief. The restore is the only part "
            "anybody ever actually needs.",
            ["Schedule the restore, not only the dump.",
             "Measure how long a restore takes before the day it matters."],
            "2026-08-08T06:30:00.000Z"),
    item("a4", "Rebuilding a wooden dinghy over one winter",
         "Boatbuilding Weekly", "2026-08-05T12:40:00.000Z", read=True),
    summary("a4",
            "Epoxy hides a bad joint for about two seasons; the survey finds "
            "it in the third.",
            ["Strip the paint before deciding what the hull is worth.",
             "Fastenings first, cosmetics last."],
            "2026-08-05T13:10:00.000Z"),
    item("a5", "The case against ambient notifications",
         "Ink & Paper", "2026-08-03T09:15:00.000Z"),
    item("a6", "Reading RSS in 2026, deliberately",
         "Ink & Paper", "2026-07-31T20:00:00.000Z", read=True),
    summary("a6",
            "A feed reader is the last piece of software that does not decide "
            "for you what you meant to read.",
            ["Chronological is a feature, not a limitation.",
             "Subscriptions are portable; timelines are not."],
            "2026-07-31T20:26:00.000Z"),
    item("a7", "Measuring latency without lying to yourself",
         "The Morning Paper", "2026-07-28T11:30:00.000Z"),
    summary("a7",
            "Averages describe a distribution nobody is experiencing. Report "
            "percentiles or report nothing.",
            ["Coordinated omission hides the worst requests you have.",
             "A p99 over an hour is not a p99 over a minute."],
            "2026-07-28T11:52:00.000Z"),
    item("a8", "A field guide to sourdough failure",
         "Ink & Paper", "2026-07-26T07:45:00.000Z", read=True),
    summary("a8",
            "Almost every flat loaf is one of four things, and three of them "
            "are temperature.",
            ["A cold kitchen is a slow starter, not a dead one.",
             "Shape it tight; slack dough spreads instead of rising."],
            "2026-07-26T08:02:00.000Z"),
    item("a9", "Static binaries and the machines that outlive them",
         "Lime", "2026-07-24T15:10:00.000Z"),
    summary("a9",
            "Linking everything in is how a program still runs on a box "
            "nobody has patched since it was installed.",
            ["The dependency you did not ship cannot be missing.",
             "Size on disk is the cheapest thing being traded away."],
            "2026-07-24T15:30:00.000Z"),
    item("a10", "Keeping a paper notebook alongside the terminal",
         "Ink & Paper", "2026-07-21T18:00:00.000Z"),
    item("a11", "The winter storage checklist nobody follows",
         "Boatbuilding Weekly", "2026-07-19T09:25:00.000Z", read=True),
    summary("a11",
            "Water left anywhere freezes somewhere expensive; the list is "
            "mostly about draining things.",
            ["Drain the engine before the first hard night, not after.",
             "Cover it so air still moves, or the mould does the work."],
            "2026-07-19T09:44:00.000Z"),
    item("a12", "Reading the log forward, once",
         "The Morning Paper", "2026-07-17T13:05:00.000Z"),
    summary("a12",
            "An append-only log is only simple while every reader agrees "
            "where it left off.",
            ["A cursor is state; treat it like one.",
             "Re-reading from zero must stay cheap enough to be an option."],
            "2026-07-17T13:20:00.000Z"),
]

BODY = (
    "Ownership in Rust is usually taught as a memory-management story: the "
    "compiler frees things for you, so you do not have to. That is true, and "
    "it is the least interesting half of it.\n\n"
    "The rule the compiler actually enforces is about aliasing. At any moment "
    "a value may have many readers or exactly one writer, never both. "
    "Deallocation is safe because of that rule, not the other way around — "
    "which is why the same checker catches an iterator invalidated mid-loop, "
    "a data race across two threads, and a file handle used after it was "
    "handed away, none of which are allocation bugs at all.\n"
)


async def shoot() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "summareader-mcp" / "library.sqlite"
        path.parent.mkdir(parents=True)
        store = open_store(path)
        try:
            store.apply_all(RECORDS)
            store.store_body("a1", BODY)
            app = LibraryUI(store, Config.for_library(path))
            async with app.run_test(size=(118, 30)) as pilot:
                # The results, not the search box: the footer then shows every
                # key the interface has rather than only the one that leaves
                # the box, and the picture is meant to document those.
                await pilot.pause()
                app.query_one("#results").focus()
                await pilot.pause()
                app.save_screenshot(str(OUT))
        finally:
            store.close()
    print(OUT)


if __name__ == "__main__":
    asyncio.run(shoot())
