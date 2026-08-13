"""The terminal interface, driven headlessly.

Textual can run an app without a terminal, so this asks the real widgets real
questions rather than checking that the module imports.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from textual.widgets import DataTable, Input, Static

from summareader_mcp.config import Config
from summareader_mcp.protocol.records import LogOp, LogRecord
from summareader_mcp.store import open_store
from summareader_mcp.tui import LibraryUI


def item(id: str, title: str, source: str, read: bool = False):
    return LogRecord(
        op=LogOp.ITEM,
        id=id,
        data={
            "url": f"https://example.com/{id}",
            "title": title,
            "fetched": "2026-08-01T10:00:00.000Z",
            "channels": [
                {"id": source, "kind": "rss", "url": f"https://{source}.example",
                 "title": source}
            ],
            "read": read,
        },
    )


@pytest.fixture
def app(tmp_path: Path):
    store = open_store(tmp_path / "library.sqlite")
    store.apply_all(
        [
            item("a", "Why Rust rejects this", "Lime"),
            item("b", "Buying an old boat", "Boats", read=True),
            LogRecord(
                op=LogOp.SUMMARY,
                id="b",
                data={"model": "m", "created": "2026-08-01T11:00:00.000Z",
                      "text": '{"tldr":"Surveys matter more than the hull."}'},
            ),
        ]
    )
    ui = LibraryUI(store, Config.for_library(tmp_path / "library.sqlite"))
    yield ui
    store.close()


async def test_it_opens_showing_everything(app):
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.query_one("#results", DataTable).row_count == 2
        assert "2 matching" in str(app.query_one("#status", Static).content)


async def test_typing_a_query_narrows_it(app):
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = "rust"
        await pilot.press("enter")
        await pilot.pause()
        assert app.query_one("#results", DataTable).row_count == 1


async def test_the_article_pane_shows_what_is_selected(app):
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = "boat"
        await pilot.press("enter")
        await pilot.pause()
        shown = str(app.query_one("#article", Static).content)
        assert "Buying an old boat" in shown
        assert "Surveys matter more than the hull." in shown


async def test_an_article_with_no_summary_says_so(app):
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = "rust"
        await pilot.press("enter")
        await pilot.pause()
        assert "Not summarized." in str(app.query_one("#article", Static).content)


async def test_unread_only_is_a_key(app):
    async with app.run_test() as pilot:
        # Out of the search box first: a letter typed into an Input is a
        # letter, which is the whole reason the box is focused on start.
        app.query_one(DataTable).focus()
        await pilot.pause()
        await pilot.press("u")
        await pilot.pause()
        assert app.query_one("#results", DataTable).row_count == 1
        assert "unread" in str(app.query_one("#status", Static).content)


async def test_export_writes_the_current_results(app, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = "boat"
        await pilot.press("enter")
        await pilot.pause()
        app.query_one(DataTable).focus()
        await pilot.press("e")
        await pilot.pause()

        written = list(tmp_path.glob("summareader-*.md"))
        assert len(written) == 1
        text = written[0].read_text()
        assert "Buying an old boat" in text
        assert "Why Rust" not in text, "only what was on screen"
        assert str(written[0]) in str(app.query_one("#status", Static).content)


async def test_export_with_nothing_matching_says_so(app, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = "zzzzz"
        await pilot.press("enter")
        await pilot.pause()
        app.query_one(DataTable).focus()
        await pilot.press("e")
        await pilot.pause()
        assert "nothing to export" in str(app.query_one("#status", Static).content)
        assert not list(tmp_path.glob("*.md"))


async def test_a_field_typed_into_the_box_filters_by_it(app):
    # `source: "Boats"` used to be searched for as words, which finds nothing
    # and does not say why.
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = 'source: "Boats"'
        await pilot.press("enter")
        await pilot.pause()

        table = app.query_one("#results", DataTable)
        assert table.row_count == 1
        assert "source: Boats" in str(app.query_one("#status", Static).content)


async def test_a_date_it_cannot_read_is_said_out_loud(app):
    async with app.run_test() as pilot:
        app.query_one("#query", Input).value = "since: last tuesday"
        await pilot.press("enter")
        await pilot.pause()

        assert "expected 3h" in str(app.query_one("#status", Static).content)
