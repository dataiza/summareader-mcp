"""What the log becomes once it is applied.

The previous version kept six fields in a JSON file and could answer almost
nothing. These are the questions a mirror is for, asked of records in the shape
the app actually writes.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
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

    def test_a_word_the_needle_only_ends(self, filled):
        # "rust" is in "trust" and in "crustacean", and neither is an article
        # about Rust. A match has to start where a word starts.
        filled.apply_all(
            [
                item(id="trust", title="On trust and crustaceans"),
                item(id="rustc", title="What rustc does first"),
            ]
        )
        assert sorted(i.id for i in filled.search("rust")) == ["rust", "rustc"]

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

    def test_filtering_by_title_alone(self, filled):
        # `query` would have matched the source and the body too; this is the
        # question "what did I read *called* something like this".
        assert [i.id for i in filled.search(title="old boat")] == ["boat"]
        assert filled.search(title="Boat Channel") == []

    def test_the_named_filters_match_where_a_word_starts_too(self, filled):
        filled.apply_all(
            [
                item(
                    id="trust",
                    title="On trust",
                    channels=[{"id": "c3", "kind": "rss",
                               "url": "https://t.example", "title": "Entrusted"}],
                )
            ]
        )
        assert [i.id for i in filled.search(title="rust")] == ["rust"]
        assert filled.search(source="rusted") == []

    def test_filtering_by_when_it_was_published(self, filled):
        published = datetime(2026, 8, 1, 10, tzinfo=timezone.utc)
        assert len(filled.search(since=published - timedelta(hours=1))) == 2
        assert len(filled.search(until=published - timedelta(hours=1))) == 0
        assert len(filled.search(since=published - timedelta(hours=1),
                                 until=published + timedelta(hours=1))) == 2

    def test_filtering_by_when_it_was_read(self, filled):
        filled.apply(LogRecord(op=LogOp.READ, id="boat", data={"read": True}))

        just_before = datetime.now(timezone.utc) - timedelta(minutes=1)
        assert [i.id for i in filled.search(read_since=just_before)] == ["boat"]
        assert filled.search(read_until=just_before) == []
        assert filled.search(read_since=just_before)[0].read_at is not None

    def test_unread_again_forgets_when_it_was_read(self, filled):
        filled.apply(LogRecord(op=LogOp.READ, id="boat", data={"read": True}))
        filled.apply(LogRecord(op=LogOp.READ, id="boat", data={"read": False}))

        just_before = datetime.now(timezone.utc) - timedelta(minutes=1)
        assert filled.search(read_since=just_before) == []

    def test_a_backfill_does_not_claim_everything_was_read_just_now(self, filled):
        # Replaying years of history in a minute would otherwise stamp every
        # read item with the minute the mirror was set up.
        filled.stamp_reads = False
        filled.apply(LogRecord(op=LogOp.READ, id="boat", data={"read": True}))

        read = filled.search(unread=False)
        assert [i.id for i in read] == ["boat"] and read[0].read_at is None

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


def test_tags_reach_the_mirror_and_filter(store) -> None:
    """A tag applied on a device is a tag this mirror can search by."""
    store.apply(item("a"))
    store.apply(item("b"))

    store.apply(LogRecord(op="read", id="a", data={"tags": ["Linux", "kernel"]}))

    assert [i.id for i in store.search(tags=["linux"])] == ["a"]
    # Lower-cased on the way in, so case is not a second tag.
    assert [i.id for i in store.search(tags=["Linux"])] == ["a"]
    # Two narrow rather than widen.
    assert [i.id for i in store.search(tags=["linux", "kernel"])] == ["a"]
    assert store.search(tags=["linux", "absent"]) == []


def test_a_whole_set_replaces_what_was_there(store) -> None:
    store.apply(item("a"))

    store.apply(LogRecord(op="read", id="a", data={"tags": ["linux"]}))
    store.apply(LogRecord(op="read", id="a", data={"tags": []}))

    assert store.search(tags=["linux"]) == []


def test_an_item_inherits_the_tags_of_its_source(store) -> None:
    """Tagging a feed reaches what is already in it, not only what arrives."""
    store.apply(item("a"))

    store.apply(
        LogRecord(
            op="source",
            id="ch1",
            data={"tags": ["linux"], "edited": "2026-08-16T09:00:00Z"},
        )
    )

    assert [i.id for i in store.search(tags=["linux"])] == ["a"]


def test_a_source_nobody_here_knows_is_skipped(store) -> None:
    """A label is not a reason to learn about a feed."""
    applied = store.apply(LogRecord(op="source", id="unknown", data={"tags": ["x"]}))

    assert applied is False
