"""The MCP server, over stdio or HTTP.

Tool names are unchanged from the Dart mirror — `search_library`,
`recent_items`, `library_summary` — so a client configured against that one
keeps working. What changed is that they now answer.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from datetime import datetime, timedelta, timezone

from mcp.server.mcpserver import MCPServer
from starlette.requests import Request
from starlette.responses import PlainTextResponse, Response

from . import __version__, tools
from .config import Config
from .metrics import Metrics
from .store import open_store
from .sync import Backend, Puller

log = logging.getLogger("summareader_mcp")

PULL_EVERY = timedelta(minutes=5)


def serve(config: Config, *, transport: str = "stdio", port: int = 8100) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        # stderr always: stdout is the MCP transport, and a log line written
        # there is a protocol error rather than a log line.
        stream=sys.stderr,
    )

    store = open_store(config.database, read_only=config.reads_a_local_library)
    metrics = Metrics()

    if transport == "http" and not config.http_token:
        log.warning(
            "no http_token — this port serves the whole library in plaintext to "
            "anything that can reach it. Set one, or bind it somewhere private."
        )

    server = MCPServer(
        name=config.name or "summareader",
        version=__version__,
        instructions=(
            "A mirror of somebody's reading library: articles, videos and posts "
            "they follow, most with a summary. Search it before answering "
            "questions about what they have been reading."
        ),
    )
    _register(server, store, metrics, config)

    if config.reads_a_local_library:
        log.info("reading %s, read-only; not syncing", config.database)
    else:
        _start_syncing(config, store, metrics)

    if transport == "http":
        server.settings.port = port
        server.settings.host = "0.0.0.0"
        server.run(transport="streamable-http")
    else:
        server.run(transport="stdio")
    return 0


def _register(server: MCPServer, store, metrics: Metrics, config: Config) -> None:
    @server.tool(
        name="search_library",
        description=(
            "Search the reading library by words in the title, source, summary "
            "or article text. Newest first."
        ),
    )
    def search_library(
        query: str = "",
        source: str | None = None,
        since_days: int | None = None,
        unread: bool | None = None,
        summarized: bool | None = None,
        limit: int = 20,
    ) -> dict:
        return tools.search_library(
            store,
            query,
            source=source,
            since=_since(since_days),
            unread=unread,
            summarized=summarized,
            limit=limit,
        )

    @server.tool(
        name="recent_items",
        description="The most recently published articles in the library.",
    )
    def recent_items(limit: int = 20) -> dict:
        return tools.recent_items(store, limit=limit)

    @server.tool(
        name="library_summary",
        description=(
            "How much the library holds: articles, unread, summarized, sources, "
            "and how far this mirror has read."
        ),
    )
    def library_summary() -> dict:
        return tools.library_summary(store)

    @server.tool(
        name="read_item",
        description=(
            "One article in full, including its text where the mirror holds it. "
            "Use after search_library to read something rather than guess at it."
        ),
    )
    def read_item(item_id: str) -> dict:
        return tools.read_item(store, item_id)

    @server.tool(
        name="library_report",
        description=(
            "A written report over a set of articles, as Markdown, CSV or JSON."
        ),
    )
    def library_report(
        query: str = "",
        source: str | None = None,
        since_days: int | None = None,
        fmt: str = "md",
        limit: int = 50,
    ) -> str:
        return tools.library_report(
            store, query, source=source, since=_since(since_days), fmt=fmt, limit=limit
        )

    @server.custom_route("/health", methods=["GET"])
    async def health(_: Request) -> Response:
        # Open on purpose: a health check that needs a credential is a health
        # check somebody's orchestrator cannot make.
        return PlainTextResponse("ok\n")

    @server.custom_route("/metrics", methods=["GET"])
    async def metrics_route(request: Request) -> Response:
        if not _authorised(request, config):
            return PlainTextResponse("unauthorized\n", status_code=401)
        return PlainTextResponse(
            metrics.render(store, name=config.name),
            media_type="text/plain; version=0.0.4",
        )


def _authorised(request: Request, config: Config) -> bool:
    """The same token the tools need.

    A second credential for /metrics would be ceremony: this process holds the
    master key and a plaintext copy of the library, so anything that can reach
    the port and pass the first check can already ask it for the articles.
    """
    if not config.http_token:
        return True
    header = request.headers.get("authorization", "")
    return header.removeprefix("Bearer ").strip() == config.http_token


def _start_syncing(config: Config, store, metrics: Metrics) -> None:
    """Pull now, then every five minutes, without blocking the server.

    A thread rather than a task: the store is synchronous SQLite, and the
    alternative is making every tool async to no benefit.
    """
    import threading

    def loop() -> None:
        with Backend(config.server, config.token) as backend:
            if config.name:
                try:
                    backend.rename(config.name)
                    log.info("this device is called %r on the server", config.name)
                except Exception as error:  # noqa: BLE001 — a name is not vital
                    log.info("could not set the device name: %s", error)
            puller = Puller(config, store, backend)
            while True:
                report = puller.pull()
                metrics.pulled(report.ok)
                log.info("%s", report)
                _sleep(PULL_EVERY.total_seconds())

    threading.Thread(target=loop, name="sync", daemon=True).start()


def _sleep(seconds: float) -> None:
    import time

    time.sleep(seconds)


def _since(days: int | None) -> datetime | None:
    return None if not days else datetime.now(timezone.utc) - timedelta(days=days)
