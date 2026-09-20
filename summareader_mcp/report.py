"""A set of articles, written out for somebody to read or to open elsewhere.

Shared by the CLI's `report`, the MCP tool of the same name, and the TUI's
export key — one renderer, so the three cannot drift into describing the same
library differently.

Markdown is the default because it is the one a person reads. CSV is a flat
row per article for a spreadsheet. JSON is the shape the MCP tools return.
"""

from __future__ import annotations

import csv
import io
import json
from datetime import datetime, timezone
from typing import Iterable

from .store import Item


def as_json(items: Iterable[Item]) -> str:
    return json.dumps([_plain(i) for i in items], indent=2, ensure_ascii=False)


def as_csv(items: Iterable[Item]) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(
        buffer,
        fieldnames=["published", "source", "title", "url", "read", "summary"],
        lineterminator="\n",
    )
    writer.writeheader()
    for item in items:
        writer.writerow(
            {
                "published": item.when,
                "source": item.source,
                "title": item.title,
                "url": item.url,
                "read": "yes" if item.read else "no",
                "summary": item.summary.tldr if item.summary else "",
            }
        )
    return buffer.getvalue()


def as_markdown(items: list[Item], *, title: str = "Library report") -> str:
    """The readable one: what was asked for, then each article under it."""
    if not items:
        # A heading, a count of zero and an empty source table is a document
        # that has to be read before it admits it says nothing. The other two
        # formats are for machines, where an empty list is already the answer.
        return f"# {title}\n\nNothing matched.\n"

    lines = [f"# {title}", ""]

    by_source: dict[str, int] = {}
    for item in items:
        by_source[item.source or "(no source)"] = by_source.get(item.source or "(no source)", 0) + 1
    unread = sum(1 for i in items if not i.read)
    summarized = sum(1 for i in items if i.summary)

    lines += [
        f"{len(items)} articles · {unread} unread · {summarized} summarized · "
        f"{len(by_source)} sources",
        "",
        f"*Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}*",
        "",
    ]

    if by_source:
        lines += ["| Source | Articles |", "| --- | --- |"]
        for source, count in sorted(by_source.items(), key=lambda kv: -kv[1]):
            lines.append(f"| {source} | {count} |")
        lines.append("")

    for item in items:
        lines.append(f"## {item.title}")
        meta = " · ".join(part for part in (item.source, item.when) if part)
        lines.append(f"*{meta}* — <{item.url}>" if meta else f"<{item.url}>")
        lines.append("")
        if item.summary:
            if item.summary.tldr:
                lines += [item.summary.tldr, ""]
            for point in item.summary.points:
                stamp = f"[{_mmss(point.at_ms)}] " if point.at_ms is not None else ""
                lines.append(f"- {stamp}{point.text}")
            if item.summary.points:
                lines.append("")
        else:
            lines += ["*Not summarized.*", ""]

    return "\n".join(lines).rstrip() + "\n"


def render(items: list[Item], fmt: str, *, title: str = "Library report") -> str:
    if fmt == "json":
        return as_json(items)
    if fmt == "csv":
        return as_csv(items)
    return as_markdown(items, title=title)


def _plain(item: Item) -> dict:
    return {
        "id": item.id,
        "title": item.title,
        "source": item.source,
        "url": item.url,
        "published": item.published.isoformat() if item.published else None,
        "read": item.read,
        "summary": item.summary.tldr if item.summary else None,
        "points": [p.text for p in item.summary.points] if item.summary else [],
    }


def _mmss(at_ms: int) -> str:
    seconds = at_ms // 1000
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02}:{secs:02}" if hours else f"{minutes}:{secs:02}"
