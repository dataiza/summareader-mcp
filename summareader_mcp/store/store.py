"""The library on disk, and the questions worth asking it.

One set of SQL serves two files: the mirror's own, which this module creates
and fills from the log, and the app's own, which `--library` mode opens
read-only. That is the whole reason the schema borrows the app's table and
column names — see `schema.sql`.

Read-only in both cases. The mirror pulls and serves; nothing it holds changes.
"""

from __future__ import annotations

import re
import sqlite3
import threading
from importlib import resources
from functools import lru_cache
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from ..protocol.records import LogOp, LogRecord, channel_name, channels_of
from ..summary import Summary, SummaryParseError, parse_summary_or_prose

# Asked of the package rather than of __file__: a frozen bundle has no source
# tree beside it to look next to, and this is the one lookup that has to work
# from a checkout, from a wheel and from an executable alike.
_SCHEMA = resources.files(__package__).joinpath("schema.sql")


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
    read_at: datetime | None = None

    @property
    def when(self) -> str:
        return self.published.strftime("%Y-%m-%d") if self.published else ""


@lru_cache(maxsize=256)
def _needle(needle: str) -> re.Pattern[str]:
    # A word start is "not preceded by a word character", which is what makes
    # `rust` find "Rust", "rustc" and "Rust:" while leaving "trust" alone. `\b`
    # would be wrong for a needle beginning with punctuation, where there is no
    # word boundary to find; this asks about the character before instead, and
    # so behaves the same whatever the needle starts with. `\w` is Unicode-aware
    # here, so an accented letter counts as a letter rather than as a boundary.
    return re.compile(r"(?<!\w)" + re.escape(needle), re.IGNORECASE)


def _word_start(haystack: str | None, needle: str) -> int:
    """True when `needle` appears in `haystack` starting at a word start."""
    return 1 if haystack and _needle(needle).search(haystack) else 0


def open_store(path: Path | str, *, read_only: bool = False) -> Store:
    """Open a library, creating the mirror's schema unless it is somebody's.

    `read_only` is for `--library`: the app may be running against that file,
    and a mirror has no business writing to a library it does not own.
    """
    path = Path(path)
    if read_only and not path.exists():
        # sqlite's own answer here is "unable to open database file", raised as
        # a traceback out of a `--library` typo. The path is the whole of what
        # went wrong, so the message is the path.
        raise FileNotFoundError(f"no library at {path}")
    # `check_same_thread=False` plus the lock in `_Locked`, because this store
    # is read from more than one thread: the MCP server answers each tool call
    # on a worker, and the sync loop writes from its own. sqlite3 refuses a
    # connection used off its creating thread, and the alternative — a
    # connection per thread — means every writer racing every reader for the
    # same file rather than queueing politely in one process.
    if read_only:
        connection = sqlite3.connect(
            f"file:{path}?mode=ro", uri=True, check_same_thread=False
        )
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(path, check_same_thread=False)
    connection.row_factory = sqlite3.Row
    # Both a reader and a writer can be open at once — `serve` and `ui`, or
    # this and the app. WAL and a timeout are what make that uneventful rather
    # than a SQLITE_BUSY somebody sees once a week.
    connection.execute("PRAGMA busy_timeout = 5000")
    connection.create_function("word_start", 2, _word_start, deterministic=True)
    if not read_only:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.executescript(_SCHEMA.read_text(encoding="utf-8"))
        # `CREATE TABLE IF NOT EXISTS` does nothing to a table that is already
        # there, so a column added later needs saying twice. The cache is
        # disposable and could simply be rebuilt, but a rebuild is every blob
        # downloaded again for the sake of one nullable integer.
        held = {row["name"] for row in connection.execute("PRAGMA table_info(items)")}
        if "read_at" not in held:
            connection.execute("ALTER TABLE items ADD COLUMN read_at INTEGER")
        connection.commit()
    return Store(_Locked(connection), read_only=read_only)


class _Locked:
    """One connection, one lock, and every statement materialised.

    Rows are fetched inside the lock rather than handed back as a live cursor:
    a cursor iterated after the lock is released is the same bug in a costume.
    Every query here is bounded by a LIMIT or is a write, so nothing is being
    loaded that would not have been anyway.
    """

    def __init__(self, connection: sqlite3.Connection) -> None:
        self._db = connection
        self._lock = threading.RLock()

    def execute(self, sql: str, args: Any = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._db.execute(sql, args).fetchall()

    def executescript(self, sql: str) -> None:
        with self._lock:
            self._db.executescript(sql)

    def commit(self) -> None:
        with self._lock:
            self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()


class Store:
    def __init__(self, connection: _Locked, *, read_only: bool) -> None:
        self._db = connection
        self.read_only = read_only
        # The log says an item is read; it never says when. So the arrival of
        # that record is the best this can know, which is right for a mirror
        # that was running at the time and wrong for one replaying years of
        # history in a minute — hence the puller turning it off for a backfill
        # rather than stamping ten thousand things as read this afternoon.
        self.stamp_reads = True

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
        title: str | None = None,
        source: str | None = None,
        since: datetime | None = None,
        until: datetime | None = None,
        read_since: datetime | None = None,
        read_until: datetime | None = None,
        unread: bool | None = None,
        summarized: bool | None = None,
        tags: Iterable[str] | None = None,
        limit: int = 20,
    ) -> list[Item]:
        """Everything matching, newest first.

        A scan over the columns worth searching rather than FTS5: it is honest
        about what it does, needs no index to maintain against a table the log
        rewrites, and a library of a few thousand answers instantly. FTS5 is
        the upgrade path if it ever measurably falls short.

        The needle is matched where a word starts, so `rust` finds "Rust" and
        "rustc" but not "trust". It is still a plain substring after that
        first character: the whole query, spaces and all, has to appear in one
        column in the order it was typed. It is not a word search — several
        words are not several conditions — and there is no stemming, so
        `survey` does not find "surveys".
        """
        where: list[str] = []
        args: list[Any] = []

        if query.strip():
            needle = query.strip()
            where.append(
                "(word_start(i.title, ?)"
                " OR word_start(src.name, ?)"
                " OR word_start(s.text, ?)"
                " OR word_start(t.text, ?)"
                " OR word_start(i.canonical_url, ?))"
            )
            args += [needle] * 5
        if title:
            where.append("word_start(i.title, ?)")
            args.append(title)
        if source:
            where.append("word_start(src.name, ?)")
            args.append(source)
        if since is not None:
            where.append("coalesce(i.published_at, i.fetched_at) >= ?")
            args.append(int(since.timestamp()))
        if until is not None:
            where.append("coalesce(i.published_at, i.fetched_at) <= ?")
            args.append(int(until.timestamp()))
        if read_since is not None:
            where.append("i.read_at >= ?")
            args.append(int(read_since.timestamp()))
        if read_until is not None:
            where.append("i.read_at <= ?")
            args.append(int(read_until.timestamp()))
        if unread is not None:
            where.append("i.read = ?")
            args.append(0 if unread else 1)
        if summarized is not None:
            where.append("s.text IS NOT NULL" if summarized else "s.text IS NULL")
        # An item's own tag, or a tag on any source it arrived from — the same
        # rule the app filters by, so the two answer alike. Several tags narrow
        # rather than widen.
        for tag in sorted({t.strip().lower() for t in (tags or ()) if t.strip()}):
            where.append(
                "(EXISTS (SELECT 1 FROM item_tags it"
                "          WHERE it.item_id = i.id AND it.tag = ?)"
                " OR EXISTS (SELECT 1 FROM item_channels ic"
                "              JOIN channel_tags ct ON ct.channel_id = ic.channel_id"
                "             WHERE ic.item_id = i.id AND ct.tag = ?))"
            )
            args += [tag, tag]

        sql = f"""
            SELECT i.id, i.title, i.canonical_url, i.published_at, i.fetched_at,
                   i.read, i.read_at, src.name AS source, s.text AS summary,
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
                   i.read, i.read_at, src.name AS source, s.text AS summary,
                   t.word_count AS words
            FROM items i
            {_SOURCE_JOIN}
            {_SUMMARY_JOIN}
            LEFT JOIN extracted_texts t ON t.item_id = i.id
            WHERE i.id = ?
        """
        return [self._item(row) for row in self._db.execute(sql, [item_id])]

    def body(self, item_id: str) -> str | None:
        rows = self._db.execute(
            "SELECT text FROM extracted_texts WHERE item_id = ?", [item_id]
        )
        return rows[0]["text"] if rows else None

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
        rows = self._db.execute(
            """
            SELECT (SELECT COUNT(*) FROM items) AS items,
                   (SELECT COUNT(*) FROM items WHERE read = 0) AS unread,
                   (SELECT COUNT(DISTINCT item_id) FROM summaries
                    WHERE state = 'ok' AND text IS NOT NULL) AS summarized,
                   (SELECT COUNT(*) FROM extracted_texts) AS bodies,
                   (SELECT COUNT(*) FROM channels WHERE kind <> 'saved') AS sources
            """
        )
        return dict(rows[0])

    def setting(self, key: str) -> str | None:
        try:
            rows = self._db.execute(
                "SELECT value FROM settings WHERE key = ?", [key]
            )
        except sqlite3.OperationalError:
            # `--library` mode against an app database, whose settings table
            # holds the app's own keys and not ours.
            return None
        return rows[0]["value"] if rows else None

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
            LogOp.SOURCE: self._apply_source,
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
        #
        # Tags are a whole set on the same op — present means "these and no
        # others", [] means none — and are applied whether or not the record
        # also says anything about reading.
        tagged = False
        if isinstance(record.data.get("tags"), list):
            self._write_tags("item_tags", "item_id", record.id, record.data["tags"])
            tagged = True
        if "read" not in record.data:
            return tagged
        read = bool(record.data["read"])
        if not read:
            # Unread again means the reading did not happen, so neither did
            # the time it happened at.
            self._db.execute(
                "UPDATE items SET read = 0, read_at = NULL WHERE id = ?", [record.id]
            )
        elif self.stamp_reads:
            self._db.execute(
                "UPDATE items SET read = 1, read_at = ? WHERE id = ?",
                [int(datetime.now(timezone.utc).timestamp()), record.id],
            )
        else:
            self._db.execute("UPDATE items SET read = 1 WHERE id = ?", [record.id])
        return True

    def _apply_source(self, record: LogRecord) -> bool:
        """A source's tags, as a whole set.

        A channel this mirror has never heard of is skipped rather than
        created: a label is not a reason to learn about a feed, and item
        records are what introduce one.
        """
        stated = record.data.get("tags")
        if not isinstance(stated, list):
            return False
        known = self._db.execute("SELECT 1 FROM channels WHERE id = ?", [record.id])
        if not known:
            return False
        self._write_tags("channel_tags", "channel_id", record.id, stated)
        return True

    def _write_tags(
        self, table: str, column: str, owner: str, tags: Iterable[Any]
    ) -> None:
        """The whole set, replaced.

        Lower-cased and trimmed to match how the app stores them, so a search
        does not have to case-fold.
        """
        wanted = sorted(
            {
                tag.strip().lower()
                for tag in tags
                if isinstance(tag, str) and tag.strip()
            }
        )
        self._db.execute(f"DELETE FROM {table} WHERE {column} = ?", [owner])
        for tag in wanted:
            self._db.execute(
                f"INSERT OR IGNORE INTO {table} ({column}, tag) VALUES (?, ?)",
                [owner, tag],
            )

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
            read_at=(
                datetime.fromtimestamp(row["read_at"], tz=timezone.utc)
                if "read_at" in row.keys() and row["read_at"]
                else None
            ),
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
