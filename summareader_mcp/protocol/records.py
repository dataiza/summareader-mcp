"""What a decrypted log entry says.

See `summareader/docs/SYNC_PROTOCOL.md` §4. The shape is
`{"op": …, "id": …, "data": {…}}`, and the previous version of this program
read `title` at the top level — where it is nested under `data` — and mirrored
a library of items with no titles for months without erroring once. That is
the bug this module exists to not have.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


class LogOp:
    """Every op the log carries.

    An unknown one is skipped, not failed: that is what lets a newer device
    write something this one has never heard of without stopping it.
    """

    ITEM = "item"
    SUMMARY = "summary"
    ANNOTATION = "annotation"
    READ = "read"
    TOMBSTONE = "tombstone"
    TEXT = "text"
    IMAGE = "image"

    #: A source's tags, and nothing else about it. The only record about a
    #: channel that is not nested inside an item.
    SOURCE = "source"

    KNOWN = frozenset(
        {ITEM, SUMMARY, ANNOTATION, READ, TOMBSTONE, TEXT, IMAGE, SOURCE}
    )


class TombstoneScope:
    """Which devices a deletion is about.

    `local` means "this device dropped its copy" — retention writes one on
    every purge. Honouring one would let one device's retention policy delete
    items off every other device, so only `global` removes anything, and an
    unrecognised scope is ignored. Refusing to delete is the recoverable
    mistake.
    """

    LOCAL = "local"
    GLOBAL = "global"


@dataclass(frozen=True)
class LogRecord:
    op: str
    id: str
    data: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def decode(cls, plaintext: str) -> LogRecord | None:
        """One record, or None for anything that is not one."""
        try:
            decoded = json.loads(plaintext)
        except (json.JSONDecodeError, TypeError):
            return None
        if not isinstance(decoded, dict):
            return None
        op, item_id, data = decoded.get("op"), decoded.get("id"), decoded.get("data")
        if not isinstance(op, str) or not isinstance(item_id, str):
            return None
        return cls(op=op, id=item_id, data=data if isinstance(data, dict) else {})

    def encode(self) -> str:
        return json.dumps(
            {"op": self.op, "id": self.id, "data": self.data},
            separators=(",", ":"),
            ensure_ascii=False,
        )

    @property
    def known(self) -> bool:
        return self.op in LogOp.KNOWN


def channels_of(record: LogRecord) -> list[dict[str, Any]]:
    """The memberships on an `item` record, ignoring anything malformed."""
    raw = record.data.get("channels")
    if not isinstance(raw, list):
        return []
    return [c for c in raw if isinstance(c, dict) and isinstance(c.get("id"), str)]


def channel_name(channel: dict[str, Any]) -> str:
    """What a feed is called on screen: its title, or its address.

    The same fallback the app's shelf uses. A channel is allowed to have no
    title — a feed that has never been polled has not told anyone its name yet.
    """
    title = channel.get("title")
    if isinstance(title, str) and title.strip():
        return title
    url = channel.get("url")
    return url if isinstance(url, str) else channel.get("id", "")


def source_of(record: LogRecord) -> str | None:
    """Which feed an item came from.

    **There is no `source` field.** Every screen in the app shows one and no
    record contains one — it is the first non-`saved` membership, named by
    `channel_name`. Reading `data["source"]` returns None for every item ever
    written, which is exactly what the previous version of this program did.
    """
    for channel in channels_of(record):
        if channel.get("kind") != "saved":
            return channel_name(channel)
    return None
