"""Starting the server, on either transport.

Both paths were not equally tested: stdio was driven end to end against a real
MCP client, and HTTP was not — so `server.settings.port = port` shipped, which
raises, and the container restarted forever while stdio went on working. This
is that gap closed.
"""

from __future__ import annotations

import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from summareader_mcp import server as server_module
from summareader_mcp.config import Config
from summareader_mcp.store import open_store


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

    async def test_no_token_is_401_rather_than_the_library(self):
        guarded = server_module._guarded(self._inner, "secret")
        assert (await self._get(guarded, "/mcp"))[0]["status"] == 401

    async def test_the_wrong_token_is_401_too(self):
        guarded = server_module._guarded(self._inner, "secret")
        sent = await self._get(guarded, "/mcp", [(b"authorization", b"Bearer nope")])
        assert sent[0]["status"] == 401

    async def test_the_right_one_gets_through(self):
        guarded = server_module._guarded(self._inner, "secret")
        sent = await self._get(guarded, "/mcp", [(b"authorization", b"Bearer secret")])
        assert sent[0]["status"] == 200

    async def test_health_stays_open(self):
        # An orchestrator's health check has no credential to offer, and this
        # route answers "ok" and nothing about the library.
        guarded = server_module._guarded(self._inner, "secret")
        assert (await self._get(guarded, "/health"))[0]["status"] == 200
