"""The library on disk, and the questions worth asking it.

One set of SQL serves two files: the mirror's own, which this module creates
and fills from the log, and the app's own, which `--library` mode opens
read-only. That is the whole reason the schema borrows the app's table and
column names — see `schema.sql`.

Read-only in both cases. The mirror pulls and serves; nothing it holds changes.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from ..protocol.records import LogOp, LogRecord, channel_name, channels_of
from ..summary import Summary, SummaryParseError, parse_summary_or_prose

_SCHEMA = Path(__file__).with_name("schema.sql")


@dataclass(frozen=True)
class Item:
    id: str
    title: str
    source: str
    url: str
    published: datetime | None
    read: bool
    summary: Summary | None
    words: int | None = None

    @property
    def when(self) -> str:
        return self.published.strftime("%Y-%m-%d") if self.published else ""


def open_store(path: Path | str, *, read_only: bool = False) -> Store:
    """Open a library, creating the mirror's schema unless it is somebody's.

    `read_only` is for `--library`: the app may be running against that file,
    and a mirror has no business writing to a library it does not own.
    """
    path = Path(path)
    if read_only:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    # Both a reader and a writer can be open at once — `serve` and `ui`, or
    # this and the app. WAL and a timeout are what make that uneventful rather
    # than a SQLITE_BUSY somebody sees once a week.
    connection.execute("PRAGMA busy_timeout = 5000")
    if not read_only:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.executescript(_SCHEMA.read_text())
        connection.commit()
    return Store(connection, read_only=read_only)


class Store:
    def __init__(self, connection: sqlite3.Connection, *, read_only: bool) -> None:
        self._db = connection
        self.read_only = read_only

    def close(self) -> None:
        self._db.close()

    def __enter__(self) -> "Store":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # ---- reading -------------------------------------------------------

    def search(
        self,
        query: str = "",
        *,
        source: str | None = None,
        since: datetime | None = None,
        unread: bool | None = None,
        summarized: bool | None = None,
        limit: int = 20,
    ) -> list[Item]:
        """Everything matching, newest first.

        `LIKE` over the columns worth searching rather than FTS5: it is honest
        about what it does, needs no index to maintain against a table the log
        rewrites, and a library of a few thousand answers instantly. FTS5 is
        the upgrade path if it ever measurably falls short.
        """
        where: list[str] = []
        args: list[Any] = []

        if query.strip():
            needle = f"%{query.strip().lower()}%"
            where.append(
                "(lower(coalesce(i.title,'')) LIKE ?"
                " OR lower(coalesce(src.name,'')) LIKE ?"
                " OR lower(coalesce(s.text,'')) LIKE ?"
                " OR lower(coalesce(t.text,'')) LIKE ?"
                " OR lower(i.canonical_url) LIKE ?)"
            )
            args += [needle] * 5
        if source:
            where.append("lower(coalesce(src.name,'')) LIKE ?")
            args.append(f"%{source.lower()}%")
        if since is not None:
            where.append("coalesce(i.published_at, i.fetched_at) >= ?")
            args.append(int(since.timestamp()))
        if unread is not None:
            where.append("i.read = ?")
            args.append(0 if unread else 1)
        if summarized is not None:
            where.append("s.text IS NOT NULL" if summarized else "s.text IS NULL")

        sql = f"""
            SELECT i.id, i.title, i.canonical_url, i.published_at, i.fetched_at,
                   i.read, src.name AS source, s.text AS summary,
                   t.word_count AS words
            FROM items i
            {_SOURCE_JOIN}
            {_SUMMARY_JOIN}
            LEFT JOIN extracted_texts t ON t.item_id = i.id
            {"WHERE " + " AND ".join(where) if where else ""}
            ORDER BY coalesce(i.published_at, i.fetched_at) DESC
            LIMIT ?
        """
        return [self._item(row) for row in self._db.execute(sql, [*args, limit])]

    def recent(self, limit: int = 20) -> list[Item]:
        return self.search(limit=limit)

    def item(self, item_id: str) -> Item | None:
        rows = self.search_by_id(item_id)
        return rows[0] if rows else None

    def search_by_id(self, item_id: str) -> list[Item]:
        sql = f"""
            SELECT i.id, i.title, i.canonical_url, i.published_at, i.fetched_at,
                   i.read, src.name AS source, s.text AS summary,
                   t.word_count AS words
            FROM items i
            {_SOURCE_JOIN}
            {_SUMMARY_JOIN}
            LEFT JOIN extracted_texts t ON t.item_id = i.id
            WHERE i.id = ?
        """
        return [self._item(row) for row in self._db.execute(sql, [item_id])]

    def body(self, item_id: str) -> str | None:
        row = self._db.execute(
            "SELECT text FROM extracted_texts WHERE item_id = ?", [item_id]
        ).fetchone()
        return row["text"] if row else None

    def sources(self) -> list[tuple[str, int]]:
        rows = self._db.execute(
            """
            SELECT coalesce(c.title, c.url) AS name, COUNT(*) AS n
            FROM item_channels ic
            JOIN channels c ON c.id = ic.channel_id
            WHERE c.kind <> 'saved'
            GROUP BY name ORDER BY n DESC
            """
        )
        return [(row["name"], row["n"]) for row in rows]

    def counts(self) -> dict[str, int]:
        row = self._db.execute(
            """
            SELECT (SELECT COUNT(*) FROM items) AS items,
                   (SELECT COUNT(*) FROM items WHERE read = 0) AS unread,
                   (SELECT COUNT(DISTINCT item_id) FROM summaries
                    WHERE state = 'ok' AND text IS NOT NULL) AS summarized,
                   (SELECT COUNT(*) FROM extracted_texts) AS bodies,
                   (SELECT COUNT(*) FROM channels WHERE kind <> 'saved') AS sources
            """
        ).fetchone()
        return dict(row)

    def setting(self, key: str) -> str | None:
        try:
            row = self._db.execute(
                "SELECT value FROM settings WHERE key = ?", [key]
            ).fetchone()
        except sqlite3.OperationalError:
            # `--library` mode against an app database, whose settings table
            # holds the app's own keys and not ours.
            return None
        return row["value"] if row else None

    def set_setting(self, key: str, value: str) -> None:
        self._db.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )
        self._db.commit()

    # ---- writing, from the log only ------------------------------------

    def apply(self, record: LogRecord) -> bool:
        """One decrypted record. False for anything not applied.

        Unknown ops are skipped rather than failed — that is what lets a newer
        device write something this one has never heard of.
        """
        if self.read_only:
            raise RuntimeError("this library is open read-only")
        handler = {
            LogOp.ITEM: self._apply_item,
            LogOp.SUMMARY: self._apply_summary,
            LogOp.READ: self._apply_read,
            LogOp.TEXT: self._apply_blob_pointer("text_blob"),
            LogOp.IMAGE: self._apply_blob_pointer("image_blob"),
            LogOp.TOMBSTONE: self._apply_tombstone,
        }.get(record.op)
        return bool(handler and handler(record))

    def apply_all(self, records: Iterable[LogRecord]) -> int:
        applied = sum(1 for record in records if self.apply(record))
        self._db.commit()
        return applied

    def store_body(self, item_id: str, body: str) -> None:
        self._db.execute(
            "INSERT INTO extracted_texts (item_id, text, word_count) VALUES (?,?,?) "
            "ON CONFLICT(item_id) DO UPDATE SET text = excluded.text, "
            "word_count = excluded.word_count",
            [item_id, body, len(body.split())],
        )
        self._db.commit()

    def items_wanting_bodies(self, limit: int = 200) -> list[tuple[str, str]]:
        rows = self._db.execute(
            "SELECT id, text_blob FROM items "
            "WHERE text_blob IS NOT NULL AND text_blob <> '' "
            "  AND NOT EXISTS (SELECT 1 FROM extracted_texts t WHERE t.item_id = id) "
            "ORDER BY coalesce(published_at, fetched_at) DESC LIMIT ?",
            [limit],
        )
        return [(row["id"], row["text_blob"]) for row in rows]

    def _apply_item(self, record: LogRecord) -> bool:
        data = record.data
        url = data.get("url")
        if not isinstance(url, str):
            return False

        self._db.execute(
            """
            INSERT INTO items (id, canonical_url, fetch_url, title, author, lang,
                               description, discussion_url, published_at,
                               fetched_at, duration_ms, read)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              canonical_url = excluded.canonical_url,
              fetch_url     = excluded.fetch_url,
              title         = coalesce(excluded.title, items.title),
              author        = coalesce(excluded.author, items.author),
              lang          = coalesce(excluded.lang, items.lang),
              description   = coalesce(excluded.description, items.description),
              discussion_url= coalesce(excluded.discussion_url, items.discussion_url),
              published_at  = coalesce(excluded.published_at, items.published_at),
              fetched_at    = coalesce(excluded.fetched_at, items.fetched_at),
              duration_ms   = coalesce(excluded.duration_ms, items.duration_ms),
              read          = excluded.read
            """,
            [
                record.id,
                url,
                data.get("fetch"),
                data.get("title"),
                data.get("author"),
                data.get("lang"),
                data.get("description"),
                data.get("discussion"),
                _epoch(data.get("published")),
                _epoch(data.get("fetched")),
                data.get("duration") if isinstance(data.get("duration"), int) else None,
                1 if data.get("read") else 0,
            ],
        )

        # The memberships, which is where a source comes from — there is no
        # `source` field, and reading one is what the last version did.
        for channel in channels_of(record):
            self._db.execute(
                "INSERT INTO channels (id, kind, url, title) VALUES (?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, "
                "url = excluded.url, title = coalesce(excluded.title, channels.title)",
                [
                    channel["id"],
                    channel.get("kind", ""),
                    channel.get("url", ""),
                    channel.get("title"),
                ],
            )
            self._db.execute(
                "INSERT OR IGNORE INTO item_channels (item_id, channel_id, "
                "first_seen_at) VALUES (?,?,?)",
                [record.id, channel["id"], _epoch(data.get("fetched"))],
            )
        return True

    def _apply_summary(self, record: LogRecord) -> bool:
        text = record.data.get("text")
        if not isinstance(text, str):
            return False
        self._db.execute(
            "INSERT INTO summaries (item_id, model_id, created_at, text, state) "
            "VALUES (?,?,?,?,'ok') ON CONFLICT(item_id, model_id) DO UPDATE SET "
            "created_at = excluded.created_at, text = excluded.text",
            [
                record.id,
                str(record.data.get("model") or "unknown"),
                _epoch(record.data.get("created")),
                text,
            ],
        )
        return True

    def _apply_read(self, record: LogRecord) -> bool:
        # A delta: only the fields that changed are present, so a missing
        # `read` is not `false`.
        if "read" not in record.data:
            return False
        self._db.execute(
            "UPDATE items SET read = ? WHERE id = ?",
            [1 if record.data["read"] else 0, record.id],
        )
        return True

    def _apply_blob_pointer(self, column: str):
        def apply(record: LogRecord) -> bool:
            name = record.data.get("blob")
            if not isinstance(name, str) or not name:
                return False
            self._db.execute(
                f"UPDATE items SET {column} = ? WHERE id = ?", [name, record.id]
            )
            return True

        return apply

    def _apply_tombstone(self, record: LogRecord) -> bool:
        """Only a global one deletes anything.

        `local` means "this device dropped its copy" — retention writes one on
        every purge. Honouring it here would let one device's retention policy
        empty the mirror, and an unrecognised scope is ignored for the same
        reason: refusing to delete is the recoverable mistake.
        """
        if record.data.get("scope") != "global":
            return False
        for table, column in (
            ("summaries", "item_id"),
            ("extracted_texts", "item_id"),
            ("item_channels", "item_id"),
            ("items", "id"),
        ):
            self._db.execute(f"DELETE FROM {table} WHERE {column} = ?", [record.id])
        return True

    def _item(self, row: sqlite3.Row) -> Item:
        summary = None
        raw = row["summary"]
        if raw:
            try:
                summary = parse_summary_or_prose(raw)
            except SummaryParseError:
                summary = None
        published = row["published_at"] or row["fetched_at"]
        return Item(
            id=row["id"],
            title=row["title"] or "(untitled)",
            source=row["source"] or "",
            url=row["canonical_url"],
            published=(
                datetime.fromtimestamp(published, tz=timezone.utc) if published else None
            ),
            read=bool(row["read"]),
            summary=summary,
            words=row["words"],
        )


# The source is the earliest non-saved membership, named by its title falling
# back to its address — the same fallback the app's shelf uses.
_SOURCE_JOIN = """
    LEFT JOIN (
      SELECT ic.item_id, coalesce(c.title, c.url) AS name,
             ROW_NUMBER() OVER (PARTITION BY ic.item_id
                                ORDER BY ic.first_seen_at, c.id) AS rn
      FROM item_channels ic
      JOIN channels c ON c.id = ic.channel_id
      WHERE c.kind <> 'saved'
    ) src ON src.item_id = i.id AND src.rn = 1
"""

# Newest summary wins when several models have had a go at the same item.
_SUMMARY_JOIN = """
    LEFT JOIN (
      SELECT item_id, text,
             ROW_NUMBER() OVER (PARTITION BY item_id
                                ORDER BY created_at DESC) AS rn
      FROM summaries
      -- A failed or half-written row is not a summary. The app stores those
      -- here too, so a mirror reading its file must say which it means.
      WHERE state = 'ok' AND text IS NOT NULL
    ) s ON s.item_id = i.id AND s.rn = 1
"""


def _epoch(value: Any) -> int | None:
    """An ISO-8601 string as seconds, which is how the app stores its dates."""
    if isinstance(value, int):
        return value
    if not isinstance(value, str) or not value:
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None
