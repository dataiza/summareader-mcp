"""Reading the log forward, and fetching what it points at.

The cursor lives in the store beside the library it describes, keyed by the
server's instance id. Pointing this at a different server with the same cache
resumes from a number that means nothing there, so the instance is checked
before the cursor is used, and a mismatch starts again from zero.
"""

from __future__ import annotations

import logging
import sys
from dataclasses import dataclass

from ..config import Config
from ..protocol import LogRecord, SealedBlob, SyncKeys, open_bytes, open_text
from ..protocol.envelope import image_parts
from ..store import Store, open_store
from .backend import Backend, SyncFailure

log = logging.getLogger("summareader_mcp.sync")

CURSOR = "sync.cursor"
INSTANCE = "sync.instanceId"


@dataclass(frozen=True)
class PullReport:
    entries: int
    applied: int
    bodies: int
    cursor: int
    failure: str | None = None

    @property
    def ok(self) -> bool:
        return self.failure is None

    def __str__(self) -> str:
        if self.failure:
            return f"sync failed: {self.failure}"
        return (
            f"{self.entries} entries, {self.applied} applied, "
            f"{self.bodies} bodies, cursor {self.cursor}"
        )


class Puller:
    def __init__(self, config: Config, store: Store, backend: Backend) -> None:
        self._config = config
        self._store = store
        self._backend = backend
        self._keys = SyncKeys.derive(config.master_key)

    def pull(self) -> PullReport:
        try:
            return self._pull()
        except SyncFailure as failure:
            log.warning("pull failed: %s", failure)
            return PullReport(0, 0, 0, self._cursor(), failure=str(failure))

    def _pull(self) -> PullReport:
        cursor = self._agreed_cursor()
        entries = applied = 0

        while True:
            page = self._backend.read_from(cursor, limit=500)
            if not page:
                break
            records = []
            for entry in page:
                cursor = max(cursor, entry.seq)
                entries += 1
                opened = open_text(
                    SealedBlob.from_wire(entry.payload), self._keys.log_entries
                )
                if opened is None:
                    # Sealed under another key, truncated, or not an envelope.
                    # One unreadable entry must not stop the log.
                    continue
                record = LogRecord.decode(opened)
                if record is not None:
                    records.append(record)
            applied += self._store.apply_all(records)
            self._store.set_setting(CURSOR, str(cursor))
            if len(page) < 500:
                break

        bodies = self._fetch_bodies() if self._config.fetch_bodies else 0
        return PullReport(entries, applied, bodies, cursor)

    def _agreed_cursor(self) -> int:
        """Where to read from, having checked it is the same server."""
        instance = self._backend.instance()
        known = self._store.setting(INSTANCE)
        if known and instance and known != instance:
            log.warning(
                "this is a different sync server (%s, not %s) — reading from the "
                "beginning, because a seq from one server means nothing on another",
                instance,
                known,
            )
            self._store.set_setting(CURSOR, "0")
        if instance:
            self._store.set_setting(INSTANCE, instance)
        return self._cursor()

    def _cursor(self) -> int:
        try:
            return int(self._store.setting(CURSOR) or 0)
        except ValueError:
            return 0

    def _fetch_bodies(self, batch: int = 200) -> int:
        """The article text the log only pointed at.

        The difference between searching titles and summaries and searching
        what the articles say. A server can afford the bytes where a phone
        cannot, which is why this is on by default here and off there.

        Keeps going until there is nothing left to fetch, rather than taking
        `batch` of them per pull: a backlog of a few thousand drained 200 at a
        time is hours of a mirror that answers about articles it has not read
        yet, and the point of the thing is that it has read them.
        """
        total = 0
        while True:
            arrived = self._fetch_body_batch(batch)
            total += arrived
            # No progress means what is left is unfetchable — a blob the
            # server has reclaimed, say — and those stay selected, so this is
            # the difference between draining and spinning.
            if arrived == 0:
                return total
            if total > batch:
                log.info("%d bodies so far", total)

    def _fetch_body_batch(self, limit: int) -> int:
        arrived = 0
        for item_id, name in self._store.items_wanting_bodies(limit):
            try:
                sealed = self._backend.blob(name)
            except SyncFailure as failure:
                log.debug("blob %s: %s", name, failure)
                continue
            if sealed is None:
                continue
            body = open_text(SealedBlob.from_wire(sealed), self._keys.blob_contents)
            if body:
                self._store.store_body(item_id, body)
                arrived += 1
        return arrived

    def image(self, name: str) -> tuple[str, bytes] | None:
        """A picture, for anything that wants one. Nothing does yet.

        Here because the format is easy to get wrong later and obvious now: an
        image blob is `<contentType>\\n<base64 bytes>` inside the envelope.
        """
        sealed = self._backend.blob(name)
        if sealed is None:
            return None
        raw = open_bytes(SealedBlob.from_wire(sealed), self._keys.blob_contents)
        return image_parts(raw) if raw else None


def pull_once(config: Config) -> int:
    """The `pull` subcommand: sync, say what happened, and stop."""
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    with open_store(config.database) as store, Backend(
        config.server, config.token
    ) as backend:
        report = Puller(config, store, backend).pull()
        print(report, file=sys.stderr)
        return 0 if report.ok else 1
