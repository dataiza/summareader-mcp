"""Reading a mirror over its port instead of out of its file.

A real server on a real port, answered by a real MCP client: the whole point of
`--remote` is the transport, and a mocked transport would test nothing. The
library is a `--library` one so nothing syncs.
"""

from __future__ import annotations

import socket
import threading
import time
from pathlib import Path

import httpx
import pytest

from summareader_mcp import server as server_module
from summareader_mcp.config import Config
from summareader_mcp.protocol.records import LogOp, LogRecord
from summareader_mcp.store import open_store
from summareader_mcp.store.remote import RemoteError, RemoteStore

# The same record shapes the store's own tests use — one helper, one truth
# about what the app actually writes.
from test_store import item


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest.fixture
def served(tmp_path: Path, request):
    """A mirror on a port, and the address to read it at."""
    path = tmp_path / "l.sqlite"
    with open_store(path) as store:
        store.apply_all(
            [
                item(id="rust", title="Why Rust rejects this"),
                item(id="boat", title="Buying an old boat"),
                LogRecord(
                    op=LogOp.SUMMARY,
                    id="boat",
                    data={
                        "model": "m",
                        "created": "2026-08-01T11:00:00.000Z",
                        "text": '{"tldr":"Surveys matter more than the hull."}',
                    },
                ),
            ]
        )
        store.store_body("rust", "the borrow checker is not being difficult")

    port = _free_port()
    token = getattr(request, "param", None)

    # uvicorn.run installs signal handlers, which only the main thread may do.
    # Everything else about the app is the one `serve` built, token check and
    # all — which is the half worth testing.
    import uvicorn

    holder: dict = {}

    def run_http(app, host, port):
        config = uvicorn.Config(app, host=host, port=port, log_level="error")
        holder["server"] = uvicorn.Server(config)
        holder["server"].install_signal_handlers = False
        holder["server"].run()

    server_module._run_http, original = run_http, server_module._run_http

    config = Config(
        server="",
        token="",
        master_key=b"",
        cache_dir=tmp_path,
        library=path,
        bearer_token=token,
    )
    thread = threading.Thread(
        target=server_module.serve,
        args=(config,),
        kwargs={"transport": "http", "port": port},
        daemon=True,
    )
    thread.start()

    url = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            if httpx.get(f"{url}/health", timeout=1).status_code == 200:
                break
        except httpx.HTTPError:
            time.sleep(0.05)
    else:
        pytest.fail("the server never answered /health")

    yield url
    if holder.get("server"):
        holder["server"].should_exit = True
    thread.join(timeout=5)
    server_module._run_http = original


@pytest.fixture
def remote(served):
    """`RemoteStore`s that get closed, because they now hold a session open."""
    made: list[RemoteStore] = []

    def make(url=None, **kw):
        made.append(RemoteStore(url or served, **kw))
        return made[-1]

    yield make
    for store in made:
        store.close()


class TestReadingOverThePort:
    def test_search_answers_the_same_items(self, remote):
        assert [i.id for i in remote().search("rust")] == ["rust"]

    def test_a_summary_survives_the_round_trip(self, remote):
        # The wire carries a tldr and its points, not the dataclass — and the
        # front ends read a summary off the dataclass.
        found = remote().search("surveys")
        assert found[0].summary.tldr == "Surveys matter more than the hull."

    def test_filters_reach_the_far_end(self, remote):
        store = remote()
        assert [i.id for i in store.search(summarized=True)] == ["boat"]
        assert [i.id for i in store.search(title="old boat")] == ["boat"]

    def test_a_date_filter_survives_being_a_string(self, remote):
        from datetime import datetime, timezone

        store = remote()
        before = datetime(2026, 7, 1, tzinfo=timezone.utc)
        after = datetime(2026, 9, 1, tzinfo=timezone.utc)
        assert len(store.search(since=before)) == 2
        assert store.search(since=after) == []

    def test_recent_and_counts(self, remote):
        store = remote()
        assert len(store.recent(limit=10)) == 2
        assert store.counts()["items"] == 2

    def test_the_body_comes_over_too(self, remote):
        assert "borrow checker" in remote().body("rust")

    def test_an_item_nobody_has_is_none_rather_than_an_error(self, remote):
        assert remote().item("nope") is None

    def test_the_address_may_omit_the_transport_path(self, served, remote):
        assert remote().url.endswith("/mcp")
        assert remote(served + "/mcp").url.count("/mcp") == 1

    async def test_it_answers_from_inside_an_event_loop(self, remote):
        # The case that matters: Textual runs a loop, and `asyncio.run` inside
        # one raises rather than nesting. The session lives on its own thread
        # so the caller may be in a loop or not.
        assert [i.id for i in remote().search("rust")] == ["rust"]

    def test_the_session_is_held_rather_than_redialled(self, remote):
        # A front end asks in a loop, and a connect plus an initialize per
        # question is most of what a reader would feel.
        store = remote()
        store.search("rust")
        link = store._link
        store.search("boat")
        assert store._link is link is not None

    def test_closing_ends_it_and_asking_again_dials_afresh(self, remote):
        store = remote()
        store.search("rust")
        store.close()
        assert store._link is None
        assert [i.id for i in store.search("rust")] == ["rust"]

    def test_a_mirror_that_is_not_there_says_so(self):
        store = RemoteStore(f"http://127.0.0.1:{_free_port()}")
        with pytest.raises(RemoteError):
            store.search("anything")


@pytest.mark.parametrize("served", ["s3cret"], indirect=True)
class TestWhenATokenIsSet:
    def test_without_it_the_tools_refuse_and_say_what_to_set(self, remote):
        # The transport does not carry the status up, so an unexplained "server
        # returned an error response" is what this used to be.
        with pytest.raises(RemoteError, match="SUMMAREADER_MCP_TOKEN"):
            remote().search("rust")

    def test_with_it_they_answer(self, remote):
        found = remote(token="s3cret").search("rust")
        assert [i.id for i in found] == ["rust"]


async def test_the_terminal_interface_reads_a_remote_mirror(served):
    """The whole point: the TUI as a client of a server in another process."""
    from textual.widgets import DataTable, Input

    from summareader_mcp.config import Config
    from summareader_mcp.tui import LibraryUI

    store = RemoteStore(served)
    try:
        app = LibraryUI(store, Config.for_remote(served))
        async with app.run_test() as pilot:
            await pilot.pause()
            assert app.query_one("#results", DataTable).row_count == 2
            app.query_one("#query", Input).value = "rust"
            await pilot.press("enter")
            await pilot.pause()
            assert app.query_one("#results", DataTable).row_count == 1
            # The subtitle says which library, and this one is an address.
            assert served in str(app.sub_title)
    finally:
        store.close()
