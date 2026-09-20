"""The questions, in one place.

The MCP tools, the CLI and the TUI all call these, so the three cannot answer
the same question differently. They take a Store and return plain data —
nothing here knows what a transport is.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any

from .report import render
from .store import Store

_RELATIVE = re.compile(r"^(\d+)([hdwmy])$")
_HOURS = {"h": 1, "d": 24, "w": 24 * 7, "m": 24 * 30, "y": 24 * 365}


class BadSince(ValueError):
    """A `since` that is not one of ours, rather than a guess at what it meant."""


def parse_since(value: str | None) -> datetime | None:
    """`3h`, `7d`, `3w`, or a date. One reading of it for the CLI and MCP both.

    Hours are in here because "what arrived this morning" is the question a
    reading library gets asked most, and a day was the finest it could say.
    """
    if not value:
        return None
    match = _RELATIVE.match(str(value).strip().lower())
    if match:
        hours = _HOURS[match.group(2)] * int(match.group(1))
        return datetime.now(timezone.utc) - timedelta(hours=hours)
    try:
        parsed = datetime.fromisoformat(str(value))
    except ValueError:
        raise BadSince(f"{value}: expected 3h, 7d, or a date like 2026-08-01")
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


_FIELD = re.compile(r'\b(\w+):\s*("[^"]*"|\S+)')
_ALIASES = {
    "feed": "source",
    "read": "read_since",
    "read_after": "read_since",
    "read_before": "read_until",
    "before": "until",
    "after": "since",
}
_DATES = ("since", "until", "read_since", "read_until")
_FLAGS = ("unread", "summarized")
_NO = {"no", "false", "0", "off"}


def parse_query(text: str) -> tuple[str, dict[str, Any]]:
    """`source: "Colion" since:7d rust` — words, and the fields around them.

    One box is the whole of the terminal interface's search, and typing a
    field name into it is what people do; it read the lot as words to look
    for, which finds nothing and says nothing about why.

    Anything that is not a field this knows stays part of the words, so a
    colon in a title costs a search rather than an error.
    """
    filters: dict[str, Any] = {}
    rest = text

    for match in _FIELD.finditer(text):
        key = _ALIASES.get(match.group(1).lower(), match.group(1).lower())
        value = match.group(2).strip('"')
        if key in _DATES:
            filters[key] = parse_since(value)
        elif key in _FLAGS:
            filters[key] = value.lower() not in _NO
        elif key == "tag":
            # Repeatable, and narrowing: `tag:linux tag:kernel` wants both, the
            # same as it does in the app.
            filters.setdefault("tags", []).append(value)
        elif key in ("source", "title"):
            filters[key] = value
        else:
            continue
        rest = rest.replace(match.group(0), " ", 1)

    return " ".join(rest.split()), filters


def search_library(
    store: Store,
    query: str = "",
    *,
    title: str | None = None,
    source: str | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
    read_since: datetime | None = None,
    read_until: datetime | None = None,
    unread: bool | None = None,
    summarized: bool | None = None,
    tags: list[str] | None = None,
    limit: int = 20,
) -> dict[str, Any]:
    items = store.search(
        query,
        title=title,
        source=source,
        since=since,
        until=until,
        read_since=read_since,
        read_until=read_until,
        unread=unread,
        summarized=summarized,
        tags=tags,
        limit=max(1, min(limit, 100)),
    )
    return {
        "query": query,
        "found": len(items),
        "items": _items(store, items),
    }


def recent_items(store: Store, limit: int = 20) -> dict[str, Any]:
    items = store.recent(limit=max(1, min(limit, 100)))
    return {"found": len(items), "items": _items(store, items)}


def list_tags(store: Store) -> dict[str, Any]:
    """The whole vocabulary, so `tags` is a filter something can actually use.

    Not folded into `library_summary`, which caps its sources at ten: a
    vocabulary truncated to ten is worse than none, because what is missing is
    invisible and gets searched for anyway.
    """
    found = store.tags()
    return {
        "found": len(found),
        "tags": [{"tag": tag, "items": n} for tag, n in found],
    }


def library_summary(store: Store) -> dict[str, Any]:
    counts = store.counts()
    return {
        **counts,
        "cursor": int(store.setting("sync.cursor") or 0),
        "top_sources": [
            {"source": name, "items": n} for name, n in store.sources()[:10]
        ],
    }


def read_item(store: Store, item_id: str) -> dict[str, Any]:
    """One article in full, including its text where the mirror has it.

    The tool a model reaches for after searching — without it, answering
    "what does that one actually say" means guessing from a summary.
    """
    item = store.item(item_id)
    if item is None:
        return {"found": False, "id": item_id}
    tags = store.tags_of([item_id]).get(item_id, [])
    return {"found": True, **_item(item, tags), "text": store.body(item_id)}


def library_report(
    store: Store,
    query: str = "",
    *,
    title: str | None = None,
    source: str | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
    read_since: datetime | None = None,
    read_until: datetime | None = None,
    unread: bool | None = None,
    summarized: bool | None = None,
    tags: list[str] | None = None,
    fmt: str = "md",
    limit: int = 50,
) -> str:
    """The same query as `search_library`, written out instead of returned.

    Every filter, then, and under the same names: the two are one question
    asked twice, and a report that could not be narrowed by tag or by unread
    made "everything tagged rust I have not read" unaskable although both
    halves of it existed.
    """
    items = store.search(
        query,
        title=title,
        source=source,
        since=since,
        until=until,
        read_since=read_since,
        read_until=read_until,
        unread=unread,
        summarized=summarized,
        tags=tags,
        limit=max(1, min(limit, 500)),
    )
    heading = "Library report" if not query else f"Library report — {query}"
    return render(items, fmt, title=heading)


def _items(store: Store, items: list) -> list[dict[str, Any]]:
    """A page of results with their tags, at one query for the page.

    `_item` runs per row, so asking the store per row would be a hundred round
    trips on a limit of a hundred — for a few slugs.
    """
    tags = store.tags_of([i.id for i in items])
    return [_item(i, tags.get(i.id, [])) for i in items]


def _item(item, tags: list[str] | None = None) -> dict[str, Any]:
    return {
        "id": item.id,
        "title": item.title,
        "source": item.source,
        "url": item.url,
        "published": item.published.isoformat() if item.published else None,
        "read": item.read,
        "read_at": item.read_at.isoformat() if item.read_at else None,
        "summary": item.summary.tldr if item.summary else None,
        "points": (
            [p.text for p in item.summary.points] if item.summary else []
        ),
        "words": item.words,
        # Both directions of the same fact: a model that can filter by tag can
        # now also learn one from an answer, rather than having to guess a slug
        # it was never shown.
        "tags": tags or [],
    }
