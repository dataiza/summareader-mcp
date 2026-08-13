"""What the log becomes once it is applied.

The previous version kept six fields in a JSON file and could answer almost
nothing. These are the questions a mirror is for, asked of records in the shape
the app actually writes.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from summareader_mcp.protocol.records import LogOp, LogRecord
from summareader_mcp.store import open_store


def item(id="a", title="A title", channels=None, read=False, **data):
    return LogRecord(
        op=LogOp.ITEM,
        id=id,
        data={
            "url": f"https://example.com/{id}",
            "fetch": f"https://example.com/{id}",
            "canon": 1,
            "title": title,
            "fetched": "2026-08-01T10:00:00.000Z",
            "channels": channels
            if channels is not None
            else [{"id": "ch1", "kind": "rss", "url": "https://f.example", "title": "A Feed"}],
            "read": read,
            **data,
        },
    )


@pytest.fixture
def store(tmp_path: Path):
    s = open_store(tmp_path / "library.sqlite")
    yield s
    s.close()


class TestApplyingRecords:
    def test_an_item_arrives_with_its_title_and_its_source(self, store):
        # The bug the rewrite exists for: both of these were null.
        store.apply_all([item()])
        found = store.recent()[0]
        assert found.title == "A title"
        assert found.source == "A Feed"

    def test_a_channel_with_no_title_is_named_by_its_address(self, store):
        store.apply_all(
            [item(channels=[{"id": "c", "kind": "rss", "url": "https://x.example"}])]
        )
        assert store.recent()[0].source == "https://x.example"

    def test_the_saved_shelf_is_not_a_source(self, store):
        # An article can be on a shelf and in a feed; the shelf is not where it
        # came from.
        store.apply_all(
            [
                item(
                    channels=[
                        {"id": "saved", "kind": "saved", "url": "saved"},
                        {"id": "ch1", "kind": "rss", "url": "https://f.example",
                         "title": "A Feed"},
                    ]
                )
            ]
        )
        assert store.recent()[0].source == "A Feed"

    def test_a_summary_is_a_separate_record_and_gets_parsed(self, store):
        store.apply_all(
            [
                item(),
                LogRecord(
                    op=LogOp.SUMMARY,
                    id="a",
                    data={
                        "model": "m",
                        "created": "2026-08-01T11:00:00.000Z",
                        "text": '{"tldr":"One sentence.","points":[{"text":"A point"}]}',
                    },
                ),
            ]
        )
        summary = store.recent()[0].summary
        assert summary.tldr == "One sentence."
        assert summary.points[0].text == "A point"

    def test_the_newest_summary_wins(self, store):
        store.apply_all([item()])
        for model, when, tldr in [
            ("old", "2026-08-01T10:00:00.000Z", "Older."),
            ("new", "2026-08-02T10:00:00.000Z", "Newer."),
        ]:
            store.apply_all(
                [
                    LogRecord(
                        op=LogOp.SUMMARY,
                        id="a",
                        data={"model": model, "created": when,
                              "text": '{"tldr":"%s"}' % tldr},
                    )
                ]
            )
        assert store.recent()[0].summary.tldr == "Newer."

    def test_a_read_record_is_a_delta(self, store):
        store.apply_all([item(read=False)])
        store.apply_all([LogRecord(op=LogOp.READ, id="a", data={"saved": True})])
        assert store.recent()[0].read is False, "no `read` key means unchanged"
        store.apply_all([LogRecord(op=LogOp.READ, id="a", data={"read": True})])
        assert store.recent()[0].read is True

    def test_an_unknown_op_is_skipped_rather_than_failing(self, store):
        assert store.apply(LogRecord(op="somethingNewer", id="a", data={})) is False


class TestTombstones:
    def test_a_global_one_deletes(self, store):
        store.apply_all([item()])
        store.apply_all(
            [LogRecord(op=LogOp.TOMBSTONE, id="a", data={"scope": "global"})]
        )
        assert store.recent() == []

    def test_a_local_one_does_not(self, store):
        # It means "this device dropped its copy". Honouring it would let one
        # device's retention policy empty the mirror.
        store.apply_all([item()])
        store.apply_all(
            [LogRecord(op=LogOp.TOMBSTONE, id="a", data={"scope": "local"})]
        )
        assert len(store.recent()) == 1

    def test_nor_does_a_scope_nobody_recognises(self, store):
        store.apply_all([item()])
        store.apply_all(
            [LogRecord(op=LogOp.TOMBSTONE, id="a", data={"scope": "whatever"})]
        )
        assert len(store.recent()) == 1


class TestSearching:
    @pytest.fixture
    def filled(self, store):
        store.apply_all(
            [
                item(id="rust", title="Why Rust rejects this"),
                item(
                    id="boat",
                    title="Buying an old boat",
                    channels=[{"id": "c2", "kind": "youtube",
                               "url": "https://y.example", "title": "Boat Channel"}],
                ),
                LogRecord(
                    op=LogOp.SUMMARY,
                    id="boat",
                    data={"model": "m", "created": "2026-08-01T11:00:00.000Z",
                          "text": '{"tldr":"Surveys matter more than the hull."}'},
                ),
            ]
        )
        return store

    def test_by_title(self, filled):
        assert [i.id for i in filled.search("rust")] == ["rust"]

    def test_by_source(self, filled):
        assert [i.id for i in filled.search("boat channel")] == ["boat"]

    def test_by_what_the_summary_says(self, filled):
        # Not in the title, not in the source — the reason to keep summaries.
        assert [i.id for i in filled.search("surveys")] == ["boat"]

    def test_by_the_body_when_there_is_one(self, filled):
        filled.store_body("rust", "the borrow checker is not being difficult")
        assert [i.id for i in filled.search("borrow checker")] == ["rust"]

    def test_filtering_by_source(self, filled):
        assert [i.id for i in filled.search(source="Boat")] == ["boat"]

    def test_filtering_by_whether_it_is_summarized(self, filled):
        assert [i.id for i in filled.search(summarized=True)] == ["boat"]
        assert [i.id for i in filled.search(summarized=False)] == ["rust"]

    def test_counts(self, filled):
        counts = filled.counts()
        assert counts["items"] == 2
        assert counts["summarized"] == 1
        assert counts["sources"] == 2


class TestReadOnly:
    def test_a_library_somebody_else_owns_is_not_written_to(self, tmp_path):
        owner = open_store(tmp_path / "library.sqlite")
        owner.apply_all([item()])
        owner.close()

        guest = open_store(tmp_path / "library.sqlite", read_only=True)
        assert guest.recent()[0].title == "A title"
        with pytest.raises(RuntimeError):
            guest.apply(item())
        guest.close()
