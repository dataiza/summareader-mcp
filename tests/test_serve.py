"""Starting the server, on either transport.

Both paths were not equally tested: stdio was driven end to end against a real
MCP client, and HTTP was not — so `server.settings.port = port` shipped, which
raises, and the container restarted forever while stdio went on working. This
is that gap closed.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from summareader_mcp import server as server_module
from summareader_mcp.config import Config
from summareader_mcp.store import open_store
from summareader_mcp.tools import TOOL_NAMES


@pytest.fixture
def started(tmp_path: Path, monkeypatch):
    """Runs `serve` far enough to see how the transport was started."""
    calls: list[dict] = []

    def fake_run(self, transport="stdio", **kwargs):
        calls.append({"transport": transport, **kwargs})

    def fake_http(app, host, port):
        calls.append({"transport": "streamable-http", "host": host, "port": port})

    monkeypatch.setattr(server_module.MCPServer, "run", fake_run)
    # HTTP no longer goes through `run`: the app is built so the token check can
    # be put in front of it, and this is the line that would otherwise block.
    monkeypatch.setattr(server_module, "_run_http", fake_http)
    # A real file, because a library that is not there is now an error with a
    # sentence rather than a sqlite traceback — see test_cli.
    open_store(tmp_path / "l.sqlite").close()
    return calls


def test_stdio_takes_no_address(started, tmp_path):
    server_module.serve(Config.for_library(tmp_path / "l.sqlite"), transport="stdio")
    assert started == [{"transport": "stdio"}]


def test_http_is_given_its_host_and_port(started, tmp_path):
    # The bug: these were assigned to `settings`, which has no such fields and
    # raises rather than ignoring them.
    server_module.serve(
        Config.for_library(tmp_path / "l.sqlite"), transport="http", port=9123
    )
    assert started == [
        {"transport": "streamable-http", "host": "127.0.0.1", "port": 9123}
    ]


def test_it_binds_loopback_unless_asked_otherwise(started, tmp_path):
    # A desktop client is on this machine, and every interface is a firewall
    # prompt somebody did not ask for.
    server_module.serve(Config.for_library(tmp_path / "l.sqlite"), transport="http")
    assert started[0]["host"] == "127.0.0.1"


def test_a_container_can_still_bind_every_interface(started, tmp_path):
    # Loopback inside a container is reachable by nothing, which is why the
    # Dockerfile's CMD passes this.
    server_module.serve(
        Config.for_library(tmp_path / "l.sqlite"), transport="http", host="0.0.0.0"
    )
    assert started[0]["host"] == "0.0.0.0"


class TestWhereTheAddressComesFrom:
    """Flag, environment, file, default — in that order.

    The console writes the file's half, so a config that loses to an argparse
    default nobody typed would be a window whose Address chooser did nothing.
    """

    def _config(self, tmp_path, **fields) -> Path:
        import json

        path = tmp_path / "config.json"
        path.write_text(
            json.dumps({"library": str(tmp_path / "l.sqlite"), **fields}),
            encoding="utf-8",
        )
        return path

    def test_the_file_when_no_flag_says_otherwise(self, started, tmp_path):
        from summareader_mcp.cli import main

        main([
            "--config", str(self._config(tmp_path, host="0.0.0.0", port=9000)),
            "serve", "--transport=http",
        ])
        assert started[0]["host"] == "0.0.0.0" and started[0]["port"] == 9000

    def test_the_flag_wins_over_the_file(self, started, tmp_path):
        from summareader_mcp.cli import main

        main([
            "--config", str(self._config(tmp_path, host="0.0.0.0", port=9000)),
            "serve", "--transport=http", "--host=127.0.0.1", "--port=8100",
        ])
        assert started[0]["host"] == "127.0.0.1" and started[0]["port"] == 8100


def test_an_http_port_with_no_token_is_warned_about(started, tmp_path, caplog):
    # That port serves the whole library in plaintext.
    with caplog.at_level("WARNING"):
        server_module.serve(Config.for_library(tmp_path / "l.sqlite"), transport="http")
    assert any("bearer_token" in r.message for r in caplog.records)


def test_reading_a_local_library_does_not_start_syncing(started, tmp_path, caplog):
    with caplog.at_level("INFO"):
        server_module.serve(Config.for_library(tmp_path / "l.sqlite"))
    assert any("not syncing" in r.message for r in caplog.records)


def test_syncing_can_be_switched_off(started, tmp_path, caplog, monkeypatch):
    # A mirror with a server and a key, told to hold still. No thread starts,
    # and it says so — a mirror that holds looks exactly like one whose sync
    # server is unreachable, and the difference is whether anybody chose it.
    started_threads: list = []
    monkeypatch.setattr(
        server_module.Syncer, "start", lambda self: started_threads.append(self)
    )
    config = Config(
        server="https://sync.example",
        token="t",
        master_key=b"\0" * 32,
        cache_dir=tmp_path,
        library=None,
        sync=False,
    )
    with caplog.at_level("INFO"):
        server_module.serve(config)
    assert started_threads == []
    assert any("syncing is off" in r.message for r in caplog.records)


class TestTheSyncLoop:
    """It has to be stoppable, and it has to pull when asked.

    A GUI closes its window and expects the thread to go; it presses "sync now"
    and expects a pull rather than a wait of up to five minutes.
    """

    def _syncer(self, tmp_path, monkeypatch, pulls):
        from datetime import timedelta

        class FakeBackend:
            def __init__(self, *_): pass
            def __enter__(self): return self
            def __exit__(self, *_): return False

        class FakePuller:
            def __init__(self, *_): pass
            def pull(self):
                pulls.append(1)
                return SimpleNamespace(ok=True)

        monkeypatch.setattr(server_module, "Backend", FakeBackend)
        monkeypatch.setattr(server_module, "Puller", FakePuller)
        config = Config(
            server="https://s.example", token="t", master_key=b"\0" * 32,
            cache_dir=tmp_path,
        )
        return server_module.Syncer(
            config, object(), every=timedelta(seconds=30)
        )

    def test_stop_ends_it_without_waiting_out_the_interval(
        self, tmp_path, monkeypatch
    ):
        pulls: list[int] = []
        syncer = self._syncer(tmp_path, monkeypatch, pulls)
        thread = syncer.start()
        while not pulls:
            time.sleep(0.01)
        syncer.stop()
        thread.join(timeout=2)
        assert not thread.is_alive()

    def test_pull_now_does_not_wait_either(self, tmp_path, monkeypatch):
        pulls: list[int] = []
        syncer = self._syncer(tmp_path, monkeypatch, pulls)
        thread = syncer.start()
        while not pulls:
            time.sleep(0.01)
        syncer.pull_now()
        deadline = time.monotonic() + 2
        while len(pulls) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        syncer.stop()
        thread.join(timeout=2)
        assert len(pulls) >= 2


class TestTheTokenGuardsTheTools:
    """`bearer_token` guarded /metrics and nothing else.

    Which meant the MCP endpoint — every tool, the whole library — answered
    anyone who could reach the port, while the installer and the README both
    said the token was what made that port safe.
    """

    async def _get(self, app, path, headers=()):
        sent: list[dict] = []
        scope = {"type": "http", "path": path, "method": "GET", "headers": list(headers)}

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            sent.append(message)

        await app(scope, receive, send)
        return sent

    async def _inner(self, scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"the library"})

    def _all(self, token="secret"):
        return {token: TOOL_NAMES}

    async def test_no_token_is_401_rather_than_the_library(self):
        guarded = server_module._guarded(self._inner, self._all())
        assert (await self._get(guarded, "/mcp"))[0]["status"] == 401

    async def test_the_wrong_token_is_401_too(self):
        guarded = server_module._guarded(self._inner, self._all())
        sent = await self._get(guarded, "/mcp", [(b"authorization", b"Bearer nope")])
        assert sent[0]["status"] == 401

    async def test_the_right_one_gets_through(self):
        guarded = server_module._guarded(self._inner, self._all())
        sent = await self._get(guarded, "/mcp", [(b"authorization", b"Bearer secret")])
        assert sent[0]["status"] == 200

    async def test_health_stays_open(self):
        # An orchestrator's health check has no credential to offer, and this
        # route answers "ok" and nothing about the library.
        guarded = server_module._guarded(self._inner, self._all())
        assert (await self._get(guarded, "/health"))[0]["status"] == 200


class TestEachTokenOpensItsOwnTools:
    """Several named tokens, each with a subset of the seven.

    A reader who wants an agent to search the library but not to read whole
    articles says so by giving it a token with `search_library` on it and not
    `read_item`. The old single token, which is what every documented example
    and every unit file already has, goes on opening all seven.
    """

    async def _call(self, tokens, token, tool, *, path="/mcp"):
        """POST a tools/call frame through the guard. Returns (status, body)."""
        reached: list[bytes] = []
        sent: list[dict] = []

        async def inner(scope, receive, send):
            reached.append((await receive()).get("body", b""))
            await send({"type": "http.response.start", "status": 200, "headers": []})
            await send({"type": "http.response.body", "body": b"the library"})

        frame = json.dumps(
            {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
             "params": {"name": tool, "arguments": {}}}
        ).encode()
        scope = {
            "type": "http",
            "path": path,
            "method": "POST",
            "headers": [(b"authorization", f"Bearer {token}".encode())],
        }

        async def receive():
            return {"type": "http.request", "body": frame, "more_body": False}

        async def send(message):
            sent.append(message)

        await server_module._guarded(inner, tokens)(scope, receive, send)
        body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
        return sent[0]["status"], body, reached

    def _tokens(self):
        return {
            "searcher": frozenset({"search_library", "library_summary"}),
            "everything": TOOL_NAMES,
        }

    async def test_a_token_nobody_issued_is_401(self):
        status, _, reached = await self._call(self._tokens(), "made-up", "search_library")
        assert status == 401 and reached == []

    async def test_a_tool_this_token_was_not_given_comes_back_as_an_error_frame(self):
        # Not a 401: the call was authorised, this tool was not. The frame is
        # what `forward` carries back without knowing anything about tools.
        status, body, reached = await self._call(self._tokens(), "searcher", "read_item")
        assert status == 200
        answer = json.loads(body)
        assert answer["id"] == 7
        assert "read_item" in answer["error"]["message"]
        # And the library was never asked.
        assert reached == []

    async def test_a_tool_it_was_given_goes_through_body_and_all(self):
        status, body, reached = await self._call(
            self._tokens(), "searcher", "search_library"
        )
        assert status == 200 and body == b"the library"
        # The body the guard read is still the body the app receives.
        assert json.loads(reached[0])["params"]["name"] == "search_library"

    async def test_the_legacy_bare_token_still_opens_everything(self):
        config = Config(
            server="", token="", master_key=b"", cache_dir=Path("."),
            bearer_token="old-one",
        )
        assert config.tool_tokens == {"old-one": TOOL_NAMES}
        for tool in sorted(TOOL_NAMES):
            status, body, _ = await self._call(config.tool_tokens, "old-one", tool)
            assert (status, body) == (200, b"the library"), tool

    async def test_a_named_token_and_the_bare_one_live_side_by_side(self):
        config = Config(
            server="", token="", master_key=b"", cache_dir=Path("."),
            bearer_token="old-one",
            tokens=(("searcher", "narrow", frozenset({"search_library"})),),
        )
        assert config.tool_tokens == {
            "narrow": frozenset({"search_library"}),
            "old-one": TOOL_NAMES,
        }

    async def test_anything_that_is_not_a_tool_call_is_left_alone(self):
        # initialize, ping, notifications: the guard has no opinion, and a
        # restricted token still has to be able to open a session.
        assert server_module._refused(b'{"method": "initialize", "id": 1}', frozenset()) is None
        assert server_module._refused(b"not json at all", frozenset()) is None

    async def test_metrics_takes_any_token_this_server_knows(self):
        # Decided: /metrics is outside the per-tool scheme. It is not one of
        # the seven and not an MCP call, and it answers in counts.
        config = Config(
            server="", token="", master_key=b"", cache_dir=Path("."),
            tokens=(("searcher", "narrow", frozenset({"search_library"})),),
        )
        request = SimpleNamespace(headers={"authorization": "Bearer narrow"})
        assert server_module._authorised(request, config)
        stranger = SimpleNamespace(headers={"authorization": "Bearer nope"})
        assert not server_module._authorised(stranger, config)


class TestTheLoopWatchesTheConfigFile:
    """The console writes that file, and it is not this process.

    So a mirror asked to pull every minute went on pulling every five until
    somebody restarted it, and a re-paired mirror went on presenting the token
    it started with. The loop looks at the file instead.
    """

    def _write(self, path: Path, **keys) -> None:
        import base64
        import json

        path.write_text(
            json.dumps(
                {
                    "server": "https://s.example",
                    "token": "t",
                    "master_key": base64.b64encode(b"\0" * 32).decode(),
                    **keys,
                }
            ),
            encoding="utf-8",
        )

    def _syncer(self, tmp_path, monkeypatch, pulls, *, seconds=300):
        """A loop whose backend records the address and token it was dialled on."""

        class FakeBackend:
            def __init__(self, server, token, *_):
                self.server = server
                self.token = token

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        class FakePuller:
            def __init__(self, _config, _store, backend):
                self._backend = backend

            def pull(self):
                pulls.append((self._backend.server, self._backend.token))
                return SimpleNamespace(ok=True)

        monkeypatch.setattr(server_module, "Backend", FakeBackend)
        monkeypatch.setattr(server_module, "Puller", FakePuller)
        path = tmp_path / "summareader-mcp.json"
        self._write(path, cache_dir=str(tmp_path), poll_seconds=seconds)
        config = Config.load(file=path, environment={})
        return path, server_module.Syncer(config, object())

    def _running(self, syncer, pulls):
        thread = syncer.start()
        while not pulls:
            time.sleep(0.01)
        return thread

    def _until(self, predicate, seconds=3.0):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and not predicate():
            time.sleep(0.01)
        return predicate()

    def test_a_shorter_interval_does_not_wait_out_the_longer_one(
        self, tmp_path, monkeypatch
    ):
        monkeypatch.setattr(server_module, "SLICE", 0.02)
        pulls: list[tuple] = []
        path, syncer = self._syncer(tmp_path, monkeypatch, pulls, seconds=300)
        thread = self._running(syncer, pulls)
        try:
            # Five minutes, with a second pull expected inside three seconds.
            self._write(path, cache_dir=str(tmp_path), poll_seconds=1)
            assert self._until(lambda: len(pulls) >= 2)
        finally:
            syncer.stop()
            thread.join(timeout=2)

    def test_the_next_pull_uses_the_server_and_token_now_written(
        self, tmp_path, monkeypatch
    ):
        monkeypatch.setattr(server_module, "SLICE", 0.02)
        pulls: list[tuple] = []
        path, syncer = self._syncer(tmp_path, monkeypatch, pulls, seconds=1)
        thread = self._running(syncer, pulls)
        try:
            assert pulls[0] == ("https://s.example", "t")
            self._write(
                path,
                server="https://elsewhere.example",
                token="u",
                cache_dir=str(tmp_path),
                poll_seconds=1,
            )
            assert self._until(
                lambda: ("https://elsewhere.example", "u") in pulls
            )
        finally:
            syncer.stop()
            thread.join(timeout=2)

    def test_a_file_that_will_not_parse_is_ignored_and_the_loop_carries_on(
        self, tmp_path, monkeypatch
    ):
        monkeypatch.setattr(server_module, "SLICE", 0.02)
        pulls: list[tuple] = []
        path, syncer = self._syncer(tmp_path, monkeypatch, pulls, seconds=1)
        thread = self._running(syncer, pulls)
        try:
            path.write_text('{"server": "https://half', encoding="utf-8")
            so_far = len(pulls)
            assert self._until(lambda: len(pulls) > so_far + 1)
            # Still the configuration it had, and still pulling with it.
            assert pulls[-1] == ("https://s.example", "t")
        finally:
            syncer.stop()
            thread.join(timeout=2)

    def test_the_wait_is_not_a_busy_loop(self, tmp_path, monkeypatch):
        """A look is a `stat`, and there is one every few seconds, not every
        few milliseconds. `SLICE` is left at its real value here on purpose —
        it is the number under test."""
        looks: list[Path | None] = []
        stamp = server_module._stamp
        monkeypatch.setattr(
            server_module,
            "_stamp",
            lambda path: (looks.append(path), stamp(path))[1],
        )
        pulls: list[tuple] = []
        _, syncer = self._syncer(tmp_path, monkeypatch, pulls, seconds=300)
        thread = self._running(syncer, pulls)
        try:
            counted = len(looks)
            time.sleep(0.5)
            assert len(looks) - counted <= 1
        finally:
            syncer.stop()
            thread.join(timeout=2)
