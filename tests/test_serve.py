"""Starting the server, on either transport.

Both paths were not equally tested: stdio was driven end to end against a real
MCP client, and HTTP was not — so `server.settings.port = port` shipped, which
raises, and the container restarted forever while stdio went on working. This
is that gap closed.
"""

from __future__ import annotations

from pathlib import Path

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

    monkeypatch.setattr(server_module.MCPServer, "run", fake_run)
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
        {"transport": "streamable-http", "host": "0.0.0.0", "port": 9123}
    ]


def test_it_binds_every_interface_because_a_container_publishes_the_port(
    started, tmp_path
):
    # Loopback inside a container is reachable by nothing. The boundary is the
    # published port and the token, not this address.
    server_module.serve(Config.for_library(tmp_path / "l.sqlite"), transport="http")
    assert started[0]["host"] == "0.0.0.0"


def test_an_http_port_with_no_token_is_warned_about(started, tmp_path, caplog):
    # That port serves the whole library in plaintext.
    with caplog.at_level("WARNING"):
        server_module.serve(Config.for_library(tmp_path / "l.sqlite"), transport="http")
    assert any("http_token" in r.message for r in caplog.records)


def test_reading_a_local_library_does_not_start_syncing(started, tmp_path, caplog):
    with caplog.at_level("INFO"):
        server_module.serve(Config.for_library(tmp_path / "l.sqlite"))
    assert any("not syncing" in r.message for r in caplog.records)
