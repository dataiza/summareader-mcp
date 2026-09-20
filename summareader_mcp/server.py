"""The MCP server, over stdio or HTTP.

Tool names are unchanged from the Dart mirror — `search_library`,
`recent_items`, `library_summary` — so a client configured against that one
keeps working. What changed is that they now answer.
"""

from __future__ import annotations

import logging
import secrets
import sys
import threading
import time
from datetime import timedelta
from pathlib import Path

from mcp.server.mcpserver import MCPServer
from starlette.requests import Request
from starlette.responses import PlainTextResponse, Response

from . import __version__, tools
from .tools import parse_since
from .config import Config
from .metrics import Metrics
from .store import open_store
from .sync import Backend, Puller

log = logging.getLogger("summareader_mcp")

#: How often a mirror pulls when nothing says otherwise. `poll_seconds` in the
#: config file, or SUMMAREADER_MCP_POLL, moves it.
PULL_EVERY = timedelta(minutes=5)

#: How long a wait between pulls is cut into, in seconds.
#:
#: The console writes the config file from another process, so the only way
#: this loop can learn that somebody moved the interval is to look — and what
#: it costs to look is what decides the number. A look is one `stat` of one
#: small file, a few microseconds and no parsing; the file is read again only
#: when the stat says it changed. Five seconds is soon enough that a setting
#: changed in a window appears to take effect as it is typed, and cheap enough
#: that the default five-minute wait costs sixty stats rather than the three
#: hundred a one-second slice would spend noticing something that happens
#: twice a year.
SLICE = 5.0


def serve(
    config: Config,
    *,
    transport: str = "stdio",
    host: str = "127.0.0.1",
    port: int = 8100,
) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        # stderr always: stdout is the MCP transport, and a log line written
        # there is a protocol error rather than a log line.
        stream=sys.stderr,
    )

    store = open_store(config.database, read_only=config.reads_a_local_library)
    metrics = Metrics()

    if transport == "http" and not config.bearer_token:
        log.warning(
            "no bearer_token — this port serves the whole library in plaintext to "
            "anything that can reach it. Set one, or bind it somewhere private."
        )

    server = MCPServer(
        name=config.name or "summareader",
        version=__version__,
        instructions=(
            "A copy of somebody's reading library: articles, videos and posts "
            "they follow, most with a summary. Search it before answering "
            "questions about what they have been reading."
        ),
    )
    _register(server, store, metrics, config)

    if config.reads_a_local_library:
        log.info("reading %s, read-only; not syncing", config.database)
    elif not config.sync:
        # Said rather than silent: a mirror that holds still looks exactly like
        # a mirror whose sync server is unreachable, and the difference is
        # whether anybody chose it.
        log.info("syncing is off; holding what is already here")
    else:
        syncer = Syncer(config, store, metrics)
        syncer.start()

    if transport == "http":
        # Passed to run, not set on settings: `Settings` carries the server's
        # own options — logging, lifespan, duplicate warnings — and never had a
        # host or a port. Assigning one raises, which is what a container did
        # on every restart while stdio went on working, because stdio is the
        # transport with nowhere to put a port.
        #
        # Loopback by default: on a desktop this port is for the client on the
        # same machine, and binding every interface there asks the firewall a
        # question the person did not want asked. A container needs the
        # opposite — a process bound to loopback inside one is reachable by
        # nothing — so it passes --host=0.0.0.0, and its boundary stays the
        # published port and the token. See the Dockerfile.
        # Built rather than run, because `run` gives nowhere to put the token
        # check and the tools had none: `bearer_token` guarded /metrics alone,
        # so the whole library answered anyone who could reach this port. The
        # app is the same one `run` would have built.
        app = server.streamable_http_app(host=host)
        if config.bearer_token:
            app = _guarded(app, config.bearer_token)
        _run_http(app, host, port)
    else:
        server.run(transport="stdio")
    return 0


def _run_http(app, host: str, port: int) -> None:  # pragma: no cover
    """The one line that blocks, kept apart so a test can stand in front of it."""
    import uvicorn

    uvicorn.run(app, host=host, port=port, log_level="info")


def _register(server: MCPServer, store, metrics: Metrics, config: Config) -> None:
    @server.tool(
        name="search_library",
        description=(
            "Search the reading library. `query` matches words in the title, "
            "source, summary or article text; `title` and `source` match one "
            "of those alone, partially. `since`/`until` bound when an article "
            "was published and `read_since`/`read_until` when it was read — "
            "each takes 3h, 7d, 3w, or a date like 2026-08-01. `tags` matches "
            "an article's own tags or the tags of the feed it came from, and "
            "several narrow rather than widen. Newest first."
        ),
    )
    def search_library(
        query: str = "",
        title: str | None = None,
        source: str | None = None,
        since: str | None = None,
        until: str | None = None,
        read_since: str | None = None,
        read_until: str | None = None,
        unread: bool | None = None,
        summarized: bool | None = None,
        tags: list[str] | None = None,
        limit: int = 20,
    ) -> dict:
        return tools.search_library(
            store,
            query,
            title=title,
            source=source,
            since=parse_since(since),
            until=parse_since(until),
            read_since=parse_since(read_since),
            read_until=parse_since(read_until),
            unread=unread,
            summarized=summarized,
            tags=tags,
            limit=limit,
        )

    @server.tool(
        name="recent_items",
        description="The most recently published articles in the library.",
    )
    def recent_items(limit: int = 20) -> dict:
        return tools.recent_items(store, limit=limit)

    @server.tool(
        name="list_tags",
        description=(
            "Every tag in the library, with the number of articles each one "
            "reaches — a feed's tags counting towards the articles in it, the "
            "same way search_library matches them. The vocabulary to pick "
            "`tags` from, rather than guessing at slugs."
        ),
    )
    def list_tags() -> dict:
        return tools.list_tags(store)

    @server.tool(
        name="library_summary",
        description=(
            "How much the library holds: articles, unread, summarized, sources, "
            "and how far this server has read."
        ),
    )
    def library_summary() -> dict:
        return tools.library_summary(store)

    @server.tool(
        name="read_item",
        description=(
            "One article in full, including its text where the server holds it. "
            "Use after search_library to read something rather than guess at it."
        ),
    )
    def read_item(item_id: str) -> dict:
        return tools.read_item(store, item_id)

    @server.tool(
        name="library_report",
        description=(
            "A written report over a set of articles, as Markdown, CSV or JSON. "
            "Narrowed exactly as search_library is: `query`, `title` and "
            "`source` match words, `since`/`until` bound when an article was "
            "published and `read_since`/`read_until` when it was read — each "
            "takes 3h, 7d, 3w, or a date like 2026-08-01. `tags` matches an "
            "article's own tags or the tags of the feed it came from, and "
            "several narrow rather than widen."
        ),
    )
    def library_report(
        query: str = "",
        title: str | None = None,
        source: str | None = None,
        since: str | None = None,
        until: str | None = None,
        read_since: str | None = None,
        read_until: str | None = None,
        unread: bool | None = None,
        summarized: bool | None = None,
        tags: list[str] | None = None,
        fmt: str = "md",
        limit: int = 50,
    ) -> str:
        return tools.library_report(
            store,
            query,
            title=title,
            source=source,
            since=parse_since(since),
            until=parse_since(until),
            read_since=parse_since(read_since),
            read_until=parse_since(read_until),
            unread=unread,
            summarized=summarized,
            tags=tags,
            fmt=fmt,
            limit=limit,
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
    if not config.bearer_token:
        return True
    header = request.headers.get("authorization", "")
    return _matches(header, config.bearer_token)


def _matches(header: str, token: str) -> bool:
    return secrets.compare_digest(header.removeprefix("Bearer ").strip(), token)


def _guarded(app, token: str):
    """Bearer auth in front of the whole app, /health excepted.

    ASGI rather than Starlette middleware because the app is already built and
    this is one `if`. /health stays open on purpose — a health check that needs
    a credential is one somebody's orchestrator cannot make, and it answers
    "ok" and nothing else. /metrics checks the same token again on its own; the
    second check costs nothing and keeps that route right under stdio too.
    """

    async def guard(scope, receive, send):
        if scope["type"] != "http" or scope.get("path") == "/health":
            await app(scope, receive, send)
            return
        header = ""
        for key, value in scope.get("headers") or ():
            if key == b"authorization":
                header = value.decode("latin-1")
                break
        if _matches(header, token):
            await app(scope, receive, send)
            return
        await PlainTextResponse("unauthorized\n", status_code=401)(scope, receive, send)

    return guard


class Syncer:
    """Pull now, then every five minutes, until told to stop.

    Lives outside `serve` because a front end with no MCP transport — a desktop
    window — wants the same loop, and wants to stop it and to ask for a pull
    without waiting out the interval. Hence an event waited on rather than a
    sleep: both questions are answered the moment they are asked.

    A thread rather than a task: the store is synchronous SQLite, and the
    alternative is making every tool async to no benefit.

    It also watches the file it was configured from. The console that changes
    these settings is a different process and has no way to reach this thread,
    so a loop that read the configuration once at the top was a loop that went
    on asking the old server, with the old token, at the old interval, until
    somebody restarted the mirror. The interval takes effect within a slice of
    the wait; the server and the token at the next pull, since that is the
    first moment a connection is dialled again.
    """

    def __init__(
        self,
        config: Config,
        store,
        metrics: Metrics | None = None,
        *,
        every: timedelta | None = None,
    ) -> None:
        self._config = config
        self._store = store
        self._metrics = metrics or Metrics()
        self._every = (
            every or timedelta(seconds=config.poll_seconds)
        ).total_seconds()
        # What the config file looked like the last time it was looked at. Set
        # here so that the file as it is now counts as already seen: the
        # configuration in hand was read from it.
        self._seen = _stamp(config.source)
        self._wake = threading.Event()
        self._stop = threading.Event()

    def start(self) -> threading.Thread:
        thread = threading.Thread(target=self.run, name="sync", daemon=True)
        thread.start()
        return thread

    def run(self) -> None:
        """The loop itself, on whichever thread calls this."""
        while not self._stop.is_set():
            # Dialled inside the loop rather than once around it. The sync
            # server and the device token can be rewritten while this runs,
            # and a client built at the top would go on presenting the token
            # the file held when the thread started — which is why changing
            # either used to mean restarting the whole process. The `with`
            # still closes the old one before the next is opened, and nothing
            # is listening here: an outbound connection can be redialled
            # without taking a port away from anybody.
            using = self._config
            with Backend(using.server, using.token) as backend:
                self._name(backend)
                puller = Puller(using, self._store, backend)
                # Rebuilt when the configuration is no longer the object these
                # two were built around, and only then: a file that was
                # rewritten with the same contents in it leaves this alone.
                while not self._stop.is_set() and self._config is using:
                    report = puller.pull()
                    self._metrics.pulled(report.ok)
                    log.info("%s", report)
                    self._wait()

    def _wait(self) -> None:
        """Hold until the next pull is due, watching the config file as it goes.

        The interval is measured from the pull rather than from the moment
        somebody changed it, which is what makes a shortened one take effect
        at once instead of waiting the old one out — and a lengthened one keep
        a pull that was already due rather than postponing it. Leaving early
        is `pull_now` or `stop`; both set the same event.
        """
        began = time.monotonic()
        while not self._stop.is_set():
            # Read afresh each time round, because `_reload` moves it.
            left = self._every - (time.monotonic() - began)
            if left <= 0:
                return
            if self._wake.wait(min(SLICE, left)):
                self._wake.clear()
                return
            self._reload()

    def _reload(self) -> None:
        """Take the config file again, when it is not the one already in hand.

        Cheap in the ordinary case, which is every case: a `stat` says whether
        anything moved, and the file is opened and parsed only when it did.
        """
        stamp = _stamp(self._config.source)
        if stamp is None or stamp == self._seen:
            return
        self._seen = stamp
        try:
            fresh = Config.load(file=self._config.source)
        except Exception as error:  # noqa: BLE001 — anything the file managed to be
            # A file caught between a write and its rename, or one somebody is
            # editing by hand. Keeping what is already in hand is the only
            # reading of a configuration that does not parse; it certainly
            # does not mean stop syncing.
            log.warning("ignoring %s for now: %s", self._config.source, error)
            return
        if fresh == self._config:
            return
        log.info("%s changed; taking it", self._config.source)
        self._config = fresh
        # Whatever `every` was given at construction holds only until the file
        # says otherwise, which is the whole point of watching it.
        self._every = float(fresh.poll_seconds)

    def pull_now(self) -> None:
        """Cut the wait short. The pull itself is unchanged."""
        self._wake.set()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    def _name(self, backend: Backend) -> None:
        if not self._config.name:
            return
        try:
            backend.rename(self._config.name)
            log.info("this device is called %r on the server", self._config.name)
        except Exception as error:  # noqa: BLE001 — a name is not vital
            log.info("could not set the device name: %s", error)


def _stamp(path: Path | None) -> tuple[int, int] | None:
    """What one `stat` says about the config file, or None when it cannot say.

    None also for a file that is briefly not there: the console writes through
    a rename, and the next look is a few seconds away.
    """
    if path is None:
        return None
    try:
        found = path.stat()
    except OSError:
        return None
    return found.st_mtime_ns, found.st_size


# `_since` lived here too, taking whole days. One parser now, in tools.
