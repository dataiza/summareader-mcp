"""Reading the log forward, against a server that behaves and one that does not."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

from summareader_mcp.config import Config
from summareader_mcp.protocol import LogOp, LogRecord, SyncKeys, blob_name
from summareader_mcp.protocol.envelope import seal_bytes, seal_text
from summareader_mcp.store import open_store
from summareader_mcp.sync.backend import Entry, SyncFailure
from summareader_mcp.sync.puller import CURSOR, INSTANCE, Puller

MASTER = bytes(range(32))


class FakeBackend:
    """A sync server, minus the network."""

    def __init__(self, *, instance: str = "server-1") -> None:
        self.keys = SyncKeys.derive(MASTER)
        self.entries: list[Entry] = []
        self.blobs: dict[str, str] = {}
        self._instance = instance
        self.renamed: list[str] = []
        self.reads: list[int] = []

    def append(self, record: LogRecord) -> None:
        self.entries.append(
            Entry(
                seq=len(self.entries) + 1,
                payload=seal_text(record.encode(), self.keys.log_entries).to_wire(),
            )
        )

    def put_body(self, text: str) -> str:
        name = blob_name(text.encode(), self.keys.blob_names)
        self.blobs[name] = seal_bytes(text.encode(), self.keys.blob_contents).to_wire()
        return name

    # the Backend surface the puller uses
    def instance(self) -> str:
        return self._instance

    def read_from(self, seq: int, *, limit: int = 500) -> list[Entry]:
        self.reads.append(seq)
        return [e for e in self.entries if e.seq > seq][:limit]

    def blob(self, name: str) -> str | None:
        return self.blobs.get(name)

    def rename(self, label: str) -> None:
        self.renamed.append(label)


def config(tmp_path: Path, **kwargs) -> Config:
    return Config(
        server="https://sync.example",
        token="t",
        master_key=MASTER,
        cache_dir=tmp_path,
        **kwargs,
    )


def item(id="a", title="A title"):
    return LogRecord(
        op=LogOp.ITEM,
        id=id,
        data={
            "url": f"https://example.com/{id}",
            "title": title,
            "fetched": "2026-08-01T10:00:00.000Z",
            "channels": [
                {"id": "c", "kind": "rss", "url": "https://f.example", "title": "A Feed"}
            ],
            "read": False,
        },
    )


@pytest.fixture
def parts(tmp_path):
    store = open_store(tmp_path / "library.sqlite")
    backend = FakeBackend()
    yield config(tmp_path), store, backend
    store.close()


class TestPulling:
    def test_entries_become_articles(self, parts):
        cfg, store, backend = parts
        backend.append(item())
        report = Puller(cfg, store, backend).pull()

        assert report.ok and report.applied == 1
        found = store.recent()[0]
        assert found.title == "A title" and found.source == "A Feed"

    def test_the_cursor_moves_and_is_resumed_from(self, parts):
        cfg, store, backend = parts
        backend.append(item(id="a"))
        Puller(cfg, store, backend).pull()
        backend.append(item(id="b"))
        Puller(cfg, store, backend).pull()

        assert backend.reads == [0, 1], "the second pull asked from where it stopped"
        assert store.setting(CURSOR) == "2"
        assert len(store.recent()) == 2

    def test_an_entry_sealed_under_another_key_is_skipped_not_fatal(self, parts):
        cfg, store, backend = parts
        stranger = SyncKeys.derive(bytes(range(1, 33)))
        backend.entries.append(
            Entry(seq=1, payload=seal_text("{}", stranger.log_entries).to_wire())
        )
        backend.append(item())

        report = Puller(cfg, store, backend).pull()

        assert report.ok and report.applied == 1
        assert report.entries == 2, "both were seen; one was unreadable"

    def test_rubbish_in_the_log_does_not_stop_it(self, parts):
        cfg, store, backend = parts
        backend.entries.append(Entry(seq=1, payload="not-an-envelope"))
        backend.append(item())

        assert Puller(cfg, store, backend).pull().applied == 1

    def test_a_failing_server_is_reported_rather_than_raised(self, parts):
        cfg, store, backend = parts

        def refuse(seq, *, limit=500):
            raise SyncFailure("the server said no", status=503)

        backend.read_from = refuse
        report = Puller(cfg, store, backend).pull()

        assert not report.ok and "said no" in report.failure


class TestReadTimes:
    def test_a_first_pull_invents_no_read_times(self, parts):
        # Everything the log has ever said arrives in one pull. Those items
        # were read whenever they were read, which this cannot know.
        cfg, store, backend = parts
        backend.append(item())
        backend.append(LogRecord(op=LogOp.READ, id="a", data={"read": True}))

        Puller(cfg, store, backend).pull()

        assert store.item("a").read is True
        assert store.item("a").read_at is None

    def test_a_pull_that_is_keeping_up_stamps_them(self, parts):
        cfg, store, backend = parts
        backend.append(item())
        Puller(cfg, store, backend).pull()  # now caught up

        backend.append(LogRecord(op=LogOp.READ, id="a", data={"read": True}))
        Puller(cfg, store, backend).pull()

        assert store.item("a").read_at is not None


class TestADifferentServer:
    def test_starts_again_rather_than_resuming_a_meaningless_cursor(self, parts):
        # seq is transport-local: entry 40 elsewhere is not this entry 40, and
        # resuming would skip everything below the old high-water mark.
        cfg, store, backend = parts
        backend.append(item())
        Puller(cfg, store, backend).pull()
        assert store.setting(INSTANCE) == "server-1"

        moved = FakeBackend(instance="server-2")
        moved.append(item(id="z", title="Somewhere else"))
        Puller(cfg, store, moved).pull()

        assert moved.reads == [0]
        assert {i.id for i in store.recent()} == {"a", "z"}


class TestBodies:
    def test_the_text_a_pointer_pointed_at_arrives(self, parts):
        cfg, store, backend = parts
        name = backend.put_body("the borrow checker is not being difficult")
        backend.append(item())
        backend.append(LogRecord(op=LogOp.TEXT, id="a", data={"blob": name}))

        report = Puller(cfg, store, backend).pull()

        assert report.bodies == 1
        assert "borrow checker" in store.body("a")
        assert [i.id for i in store.search("borrow checker")] == ["a"]

    def test_a_backlog_is_drained_rather_than_taken_a_batch_per_pull(self, parts):
        # 200 at a time meant a mirror that had not read the articles it was
        # being asked about until hours after it said it held them.
        cfg, store, backend = parts
        for n in range(7):
            name = backend.put_body(f"body {n}")
            backend.append(item(id=f"i{n}", title=f"Item {n}"))
            backend.append(LogRecord(op=LogOp.TEXT, id=f"i{n}", data={"blob": name}))

        # Items in, bodies deliberately left behind, then drained two at a
        # time — which is the shape of a first run against a real library.
        Puller(replace(cfg, fetch_bodies=False), store, backend).pull()
        assert store.body("i0") is None

        assert Puller(cfg, store, backend)._fetch_bodies(batch=2) == 7
        assert all(store.body(f"i{n}") for n in range(7))

    def test_draining_stops_at_what_cannot_be_fetched(self, parts):
        # The unfetchable stay selected, so a drain that only checked for a
        # full batch would ask for them forever.
        cfg, store, backend = parts
        name = backend.put_body("here")
        backend.append(item(id="have", title="Have"))
        backend.append(LogRecord(op=LogOp.TEXT, id="have", data={"blob": name}))
        backend.append(item(id="gone", title="Gone"))
        backend.append(LogRecord(op=LogOp.TEXT, id="gone", data={"blob": "gone"}))

        report = Puller(cfg, store, backend).pull()

        assert report.ok and report.bodies == 1

    def test_a_blob_the_server_no_longer_has_is_not_an_error(self, parts):
        # Retention on the device that wrote it can reclaim the bytes while the
        # pointer stays in the log.
        cfg, store, backend = parts
        backend.append(item())
        backend.append(LogRecord(op=LogOp.TEXT, id="a", data={"blob": "gone"}))

        report = Puller(cfg, store, backend).pull()

        assert report.ok and report.bodies == 0

    def test_they_can_be_switched_off(self, tmp_path):
        store = open_store(tmp_path / "l.sqlite")
        backend = FakeBackend()
        name = backend.put_body("words")
        backend.append(item())
        backend.append(LogRecord(op=LogOp.TEXT, id="a", data={"blob": name}))

        report = Puller(config(tmp_path, fetch_bodies=False), store, backend).pull()

        assert report.bodies == 0 and store.body("a") is None
        store.close()
