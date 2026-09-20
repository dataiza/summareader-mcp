"""What the tools answer, as opposed to what the store holds.

The store is tested next door. These are the questions the MCP surface is
asked, and the one thing worth proving about a controlled vocabulary: that
searching for what the list offers returns what the list promised.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from summareader_mcp import tools
from summareader_mcp.protocol.records import LogOp, LogRecord
from summareader_mcp.store import open_store


def item(id="a", title="A title", channels=None, **data):
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
            "read": False,
            **data,
        },
    )


def tagged(item_id: str, *tags: str) -> LogRecord:
    return LogRecord(op="read", id=item_id, data={"tags": list(tags)})


@pytest.fixture
def store(tmp_path: Path):
    s = open_store(tmp_path / "library.sqlite")
    yield s
    s.close()


@pytest.fixture
def library(store):
    """Three articles in two feeds, tagged both ways round.

    `c` carries `linux` itself *and* sits in a feed tagged `linux`, which is
    the case a count of rows gets wrong and a count of items gets right.
    """
    other = [{"id": "ch2", "kind": "rss", "url": "https://g.example", "title": "Other"}]
    store.apply_all([item("a"), item("b"), item("c", channels=other)])
    store.apply(tagged("a", "Linux", "kernel"))
    store.apply(tagged("c", "linux"))
    store.apply(
        LogRecord(
            op="source",
            id="ch2",
            data={"tags": ["linux", "weekly"], "edited": "2026-08-16T09:00:00Z"},
        )
    )
    return store


def test_the_list_of_tags_is_what_searching_for_them_returns(library):
    """The check the vocabulary is for: the list and the filter must agree.

    A slug that matched nothing, or a count that did not survive being
    searched for, would make the list a lie — and a model has no other way of
    finding out.
    """
    listed = tools.list_tags(library)

    assert listed["found"] == 3
    for row in listed["tags"]:
        found = tools.search_library(library, tags=[row["tag"]])
        assert found["found"] == row["items"], row["tag"]


def test_a_tag_counts_items_rather_than_the_rows_carrying_it(library):
    # `c` is tagged `linux` twice over — once itself, once through its feed.
    counts = {row["tag"]: row["items"] for row in tools.list_tags(library)["tags"]}
    assert counts == {"linux": 2, "kernel": 1, "weekly": 1}


def test_tags_come_back_on_every_item(library):
    by_id = {i["id"]: i["tags"] for i in tools.search_library(library)["items"]}

    assert by_id["a"] == ["kernel", "linux"]
    assert by_id["b"] == []
    # Inherited from the feed, and the item's own, without a duplicate.
    assert by_id["c"] == ["linux", "weekly"]

    recent = {i["id"]: i["tags"] for i in tools.recent_items(library)["items"]}
    assert recent == by_id
    assert tools.read_item(library, "a")["tags"] == ["kernel", "linux"]


def test_an_empty_library_has_an_empty_vocabulary(store):
    assert tools.list_tags(store) == {"found": 0, "tags": []}


def test_a_report_takes_every_filter_a_search_does(library):
    """"Everything tagged linux I have not read" — both halves existed already.

    The report passed five of the ten filters `search` accepts, so the two
    tools described the same query differently depending on which you asked.
    """
    report = tools.library_report(library, tags=["linux"], unread=True)

    assert "A title" in report
    # `b` carries no tag, so a report narrowed by one must not reach it.
    assert report.count("## ") == 2

    assert tools.library_report(library, tags=["linux"], unread=False) == (
        "# Library report\n\nNothing matched.\n"
    )


def test_a_report_over_nothing_says_so(library):
    # It used to be a heading, a count of zero and an empty table — a document
    # that has to be read before it admits it holds nothing.
    assert tools.library_report(library, tags=["absent"]) == (
        "# Library report\n\nNothing matched.\n"
    )
    # The machine formats are already unambiguous when empty.
    assert tools.library_report(library, tags=["absent"], fmt="json") == "[]"
