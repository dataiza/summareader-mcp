"""The questions, in one place.

The MCP tools, the CLI and the TUI all call these, so the three cannot answer
the same question differently. They take a Store and return plain data —
nothing here knows what a transport is.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from .report import render
from .store import Store


def search_library(
    store: Store,
    query: str = "",
    *,
    source: str | None = None,
    since: datetime | None = None,
    unread: bool | None = None,
    summarized: bool | None = None,
    limit: int = 20,
) -> dict[str, Any]:
    items = store.search(
        query,
        source=source,
        since=since,
        unread=unread,
        summarized=summarized,
        limit=max(1, min(limit, 100)),
    )
    return {
        "query": query,
        "found": len(items),
        "items": [_item(i) for i in items],
    }


def recent_items(store: Store, limit: int = 20) -> dict[str, Any]:
    items = store.recent(limit=max(1, min(limit, 100)))
    return {"found": len(items), "items": [_item(i) for i in items]}


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
    return {"found": True, **_item(item), "text": store.body(item_id)}


def library_report(
    store: Store,
    query: str = "",
    *,
    source: str | None = None,
    since: datetime | None = None,
    fmt: str = "md",
    limit: int = 50,
) -> str:
    items = store.search(
        query, source=source, since=since, limit=max(1, min(limit, 500))
    )
    title = "Library report" if not query else f"Library report — {query}"
    return render(items, fmt, title=title)


def _item(item) -> dict[str, Any]:
    return {
        "id": item.id,
        "title": item.title,
        "source": item.source,
        "url": item.url,
        "published": item.published.isoformat() if item.published else None,
        "read": item.read,
        "summary": item.summary.tldr if item.summary else None,
        "points": (
            [p.text for p in item.summary.points] if item.summary else []
        ),
        "words": item.words,
    }
