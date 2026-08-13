"""The command line, and the reports it writes."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from summareader_mcp.cli import _since, main
from summareader_mcp.config import ConfigError
from summareader_mcp.protocol.records import LogOp, LogRecord
from summareader_mcp.report import as_csv, as_markdown
from summareader_mcp.store import open_store


@pytest.fixture
def library(tmp_path: Path) -> Path:
    path = tmp_path / "library.sqlite"
    store = open_store(path)
    store.apply_all(
        [
            LogRecord(
                op=LogOp.ITEM,
                id="a",
                data={
                    "url": "https://example.com/a",
                    "title": "A first article",
                    "fetched": "2026-08-01T10:00:00.000Z",
                    "channels": [
                        {"id": "c", "kind": "rss", "url": "https://f.example",
                         "title": "A Feed"}
                    ],
                    "read": False,
                },
            ),
            LogRecord(
                op=LogOp.SUMMARY,
                id="a",
                data={"model": "m", "created": "2026-08-01T11:00:00.000Z",
                      "text": '{"tldr":"What it says.","points":[{"text":"[00:30] A point"}]}'},
            ),
        ]
    )
    store.close()
    return path


class TestReadingSomebodyElsesLibrary:
    def test_status_says_it_is_not_syncing(self, library, capsys):
        assert main(["--library", str(library), "status"]) == 0
        out = capsys.readouterr().out
        assert "read-only" in out
        assert "1 articles" in out

    def test_search_finds_by_title(self, library, capsys):
        assert main(["--library", str(library), "search", "first"]) == 0
        assert "A first article" in capsys.readouterr().out

    def test_search_says_so_when_nothing_matches(self, library, capsys):
        assert main(["--library", str(library), "search", "zzzz"]) == 0
        assert "Nothing matches" in capsys.readouterr().err

    def test_json_output_is_machine_readable(self, library, capsys):
        assert main(["--library", str(library), "search", "--format", "json"]) == 0
        parsed = json.loads(capsys.readouterr().out)
        assert parsed[0]["source"] == "A Feed"
        assert parsed[0]["summary"] == "What it says."

    def test_a_report_goes_to_a_file(self, library, tmp_path, capsys):
        out = tmp_path / "report.md"
        assert main(["--library", str(library), "report", "--out", str(out)]) == 0
        assert "A first article" in out.read_text()
        assert str(out) in capsys.readouterr().err


class TestReports:
    def _items(self, library):
        store = open_store(library, read_only=True)
        items = store.recent()
        store.close()
        return items

    def test_markdown_carries_the_summary_and_its_points(self, library):
        text = as_markdown(self._items(library))
        assert "## A first article" in text
        assert "What it says." in text
        assert "- [0:30] A point" in text, "a video point keeps its timestamp"

    def test_markdown_says_when_something_is_not_summarized(self, tmp_path):
        store = open_store(tmp_path / "l.sqlite")
        store.apply_all(
            [
                LogRecord(
                    op=LogOp.ITEM,
                    id="b",
                    data={"url": "https://e.example/b", "title": "Bare",
                          "fetched": "2026-08-01T10:00:00.000Z", "channels": [],
                          "read": False},
                )
            ]
        )
        items = store.recent()
        store.close()
        assert "*Not summarized.*" in as_markdown(items)

    def test_csv_is_one_row_per_article(self, library):
        rows = as_csv(self._items(library)).strip().splitlines()
        assert rows[0].startswith("published,source,title")
        assert len(rows) == 2


class TestSince:
    def test_relative(self):
        week = _since("7d")
        assert abs((datetime.now(timezone.utc) - week) - timedelta(days=7)).seconds < 5

    def test_hours(self):
        # "what arrived this morning" was not expressible when a day was the
        # finest this could say.
        recent = _since("3h")
        assert abs((datetime.now(timezone.utc) - recent) - timedelta(hours=3)).seconds < 5

    def test_a_date(self):
        assert _since("2026-08-01").year == 2026

    def test_nonsense_is_refused_rather_than_guessed(self):
        with pytest.raises(ConfigError):
            _since("last tuesday")

    def test_nothing_means_no_filter(self):
        assert _since(None) is None


class TestAPathThatIsNotThere:
    def test_says_so_in_a_sentence(self, tmp_path, capsys):
        # sqlite's own answer is "unable to open database file", raised as a
        # traceback out of a typo. The path is the whole of what went wrong.
        code = main(["--library", str(tmp_path / "nope.sqlite"), "status"])
        assert code == 2
        assert "no library at" in capsys.readouterr().err
