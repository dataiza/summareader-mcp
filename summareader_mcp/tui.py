"""The library in a terminal, for searching it and writing the answer down.

Deliberately not the app's reading UI. `summareader_tui` in the main repo is
that — three panes and the same keys, for reading over SSH. This is the other
half of what a mirror is for: type a question, see what matches, export it.

So: a query at the top, results under it, the article beside them, and one key
that writes the current result set to a file.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import (
    DataTable,
    Footer,
    Header,
    Input,
    Static,
)

from .config import Config
from .report import render
from .store import Item, Store, open_store
from .tools import BadSince, parse_query


class LibraryUI(App[int]):
    CSS = """
    Screen { layout: vertical; }
    #query { dock: top; }
    #results { width: 55%; }
    #detail { width: 45%; border-left: solid $panel; }
    /* Docked, so the article scrolls under it rather than taking it away:
       four lines into a body, "what am I reading, and who wrote it" is
       exactly the question the pane stops answering. */
    #article-head { dock: top; height: auto; padding: 0 1; background: $panel; }
    #article { padding: 0 1; }
    #status { dock: bottom; height: 1; color: $text-muted; }
    """

    BINDINGS = [
        Binding("escape", "focus_query", "Search"),
        Binding("e", "export", "Export"),
        Binding("u", "toggle_unread", "Unread only"),
        Binding("s", "toggle_summarized", "Summarized only"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, store: Store, config: Config) -> None:
        super().__init__()
        self._store = store
        self._config = config
        self._items: list[Item] = []
        self._unread_only = False
        self._summarized_only = False

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        yield Input(
            placeholder='Words, or source:"Colion Noir" title:rust since:7d unread:yes',
            id="query",
        )
        with Horizontal():
            yield DataTable(id="results", cursor_type="row")
            with Vertical(id="detail"):
                yield Static("", id="article-head", markup=False)
                with VerticalScroll():
                    yield Static("", id="article", markup=False)
        yield Static("", id="status")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#results", DataTable)
        table.add_columns("", "Date", "Source", "Title")
        self.title = "SummaReader"
        self.sub_title = str(self._config.database)
        self._run_search("")
        self.query_one("#query", Input).focus()

    # ---- searching -----------------------------------------------------

    @on(Input.Submitted, "#query")
    def _submitted(self, event: Input.Submitted) -> None:
        self._run_search(event.value)
        self.query_one("#results", DataTable).focus()

    def _run_search(self, query: str) -> None:
        try:
            words, typed = parse_query(query)
        except BadSince as bad:
            # A date nobody can read is worth saying so about, rather than
            # quietly searching for the letters in it.
            self._say(str(bad))
            return

        # The keys the toggles set, unless the query said otherwise: what was
        # typed is more specific than a key pressed earlier.
        if self._unread_only:
            typed.setdefault("unread", True)
        if self._summarized_only:
            typed.setdefault("summarized", True)

        self._items = self._store.search(words, limit=200, **typed)
        table = self.query_one("#results", DataTable)
        table.clear()
        for item in self._items:
            table.add_row(
                " " if item.read else "•",
                item.when,
                item.source[:22],
                item.title[:80],
            )
        filters = [
            f"{name}: {value:%Y-%m-%d %H:%M}"
            if hasattr(value, "year")
            else (name if value is True else f"{name}: {value}")
            for name, value in typed.items()
        ]
        suffix = f" · {' · '.join(filters)}" if filters else ""
        self._say(f"{len(self._items)} matching{suffix}")
        self._show(0 if self._items else None)

    @on(DataTable.RowHighlighted, "#results")
    def _highlighted(self, event: DataTable.RowHighlighted) -> None:
        self._show(event.cursor_row)

    def _show(self, index: int | None) -> None:
        pane = self.query_one("#article", Static)
        head = self.query_one("#article-head", Static)
        if index is None or not (0 <= index < len(self._items)):
            head.update("")
            pane.update("")
            return
        item = self._items[index]
        head.update(
            "\n".join(
                [item.title]
                + [m for m in [" · ".join(p for p in (item.source, item.when) if p)] if m]
            )
        )
        lines = [item.url, ""]
        if item.summary:
            if item.summary.tldr:
                lines += [item.summary.tldr, ""]
            for point in item.summary.points:
                lines.append(f"  · {point.text}")
            if item.summary.long:
                lines += ["", item.summary.long]
        else:
            lines.append("Not summarized.")
        body = self._store.body(item.id)
        if body:
            lines += ["", "─" * 40, "", body[:4000]]
        pane.update("\n".join(lines))

    # ---- the keys ------------------------------------------------------

    def action_focus_query(self) -> None:
        self.query_one("#query", Input).focus()

    def action_toggle_unread(self) -> None:
        self._unread_only = not self._unread_only
        self._run_search(self.query_one("#query", Input).value)

    def action_toggle_summarized(self) -> None:
        self._summarized_only = not self._summarized_only
        self._run_search(self.query_one("#query", Input).value)

    def action_export(self) -> None:
        """Whatever is on screen, as Markdown, next to where you started it.

        No dialog: the report is the current result set, and asking three
        questions about where to put it is three more than the moment wants.
        """
        if not self._items:
            self._say("nothing to export")
            return
        query = self.query_one("#query", Input).value.strip()
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        name = f"summareader-{stamp}.md"
        path = Path.cwd() / name
        path.write_text(
            render(
                self._items,
                "md",
                title=f"Library report — {query}" if query else "Library report",
            ),
            # utf-8, because the heading above has an em dash in it and half
            # the titles below it are not ASCII either.
            encoding="utf-8",
        )
        self._say(f"{len(self._items)} articles → {path}")

    def _say(self, message: str) -> None:
        self.query_one("#status", Static).update(message)


def run_ui(config: Config) -> int:
    store = open_store(config.database, read_only=config.reads_a_local_library)
    try:
        LibraryUI(store, config).run()
    finally:
        store.close()
    return 0
