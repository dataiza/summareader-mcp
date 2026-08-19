"""The same library, read over the port instead of out of the file.

`Store` opens `library.sqlite` directly, which is the right answer whenever the
reader and the mirror are the same machine: no port, no token, no serialization,
and it works with the server stopped. This is the other case — a terminal on a
laptop against a mirror on the box that is allowed to hold the plaintext — and
it exists so that the library stays on one host rather than on every host that
wants to read it.

It answers the same method names as `Store`, so `cli.py` and `tui.py` take
whichever object they are handed and neither knows which one it got. What it
cannot do is the writing half: this speaks the MCP tools, and the tools read.
"""

from __future__ import annotations

import asyncio
import json
import threading
from datetime import datetime
from typing import Any, Iterable

from mcp import ClientSession
from mcp.shared.exceptions import MCPError
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

from ..summary import Summary, SummaryPoint
from .store import Item


class RemoteError(RuntimeError):
    """The far end could not be reached, or would not answer."""


class RemoteStore:
    """`Store`'s reading surface, answered by a `serve --transport=http`."""

    def __init__(self, url: str, *, token: str | None = None) -> None:
        # `/mcp` is where the transport lives, and leaving it off is the
        # obvious thing to type. Adding it back beats a 404 that says nothing
        # about which half of the address was wrong.
        self.url = url.rstrip("/")
        if not self.url.endswith("/mcp"):
            self.url += "/mcp"
        self._token = token
        self._link: _Link | None = None

    # ---- reading -------------------------------------------------------

    def search(
        self,
        query: str = "",
        *,
        title: str | None = None,
        source: str | None = None,
        since: datetime | None = None,
        until: datetime | None = None,
        read_since: datetime | None = None,
        read_until: datetime | None = None,
        unread: bool | None = None,
        summarized: bool | None = None,
        tags: Iterable[str] | None = None,
        limit: int = 20,
    ) -> list[Item]:
        payload = self._call(
            "search_library",
            {
                "query": query,
                "title": title,
                "source": source,
                # The tool parses what it is given, and `fromisoformat` reads
                # back what `isoformat` wrote — so the wire carries a string
                # and both ends still mean one instant.
                "since": since.isoformat() if since else None,
                "until": until.isoformat() if until else None,
                "read_since": read_since.isoformat() if read_since else None,
                "read_until": read_until.isoformat() if read_until else None,
                "unread": unread,
                "summarized": summarized,
                "tags": list(tags) if tags else None,
                "limit": limit,
            },
        )
        return [_item(row) for row in payload.get("items", [])]

    def recent(self, limit: int = 20) -> list[Item]:
        payload = self._call("recent_items", {"limit": limit})
        return [_item(row) for row in payload.get("items", [])]

    def item(self, item_id: str) -> Item | None:
        payload = self._call("read_item", {"item_id": item_id})
        return _item(payload) if payload.get("found") else None

    def body(self, item_id: str) -> str | None:
        payload = self._call("read_item", {"item_id": item_id})
        return payload.get("text") if payload.get("found") else None

    def counts(self) -> dict[str, int]:
        payload = self._call("library_summary", {})
        return {
            key: int(payload.get(key) or 0)
            for key in ("items", "unread", "summarized", "bodies", "sources")
        }

    def sources(self) -> list[tuple[str, int]]:
        payload = self._call("library_summary", {})
        return [(row["source"], row["items"]) for row in payload.get("top_sources", [])]

    def setting(self, key: str) -> str | None:
        """Only the sync cursor, which is the only one anything here asks for.

        The settings table is not on the wire and should not be: it is where a
        mirror keeps its own bookkeeping, and a reader over the port has no
        business in it. `library_summary` publishes the one value that is
        actually a fact about the library rather than about the mirror.
        """
        if key != "sync.cursor":
            return None
        return str(self._call("library_summary", {}).get("cursor") or 0)

    def close(self) -> None:
        """Drop the session. Calling again after this dials a new one."""
        link, self._link = self._link, None
        if link is not None:
            link.close()

    def __enter__(self) -> "RemoteStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # ---- the wire ------------------------------------------------------

    def _call(self, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        link = self._link or self._connect()
        try:
            result = link.call(
                tool,
                # `None` means "not given" to the tool's defaults, and sending
                # it explicitly is how an optional filter turns into a filter
                # for nothing.
                {k: v for k, v in arguments.items() if v is not None},
            )
        except Exception as error:  # noqa: BLE001 — one message, any transport
            # A dead session stays dead, so drop it: the next call dials again
            # rather than failing forever against a connection that has gone.
            self.close()
            raise RemoteError(
                f"{self.url}: {_explain(error, self._token)}"
            ) from error
        if getattr(result, "is_error", False):
            raise RemoteError(f"{tool}: {_text(result)}")
        return _payload(tool, result)

    def _connect(self) -> "_Link":
        self._link = _Link(self.url, self._token)
        return self._link


class _Link:
    """One MCP session, held open on a thread of its own.

    Two problems, one answer. The session is kept because a front end asks in a
    loop — a search per keystroke-and-enter — and paying a connect, an
    initialize and a teardown for each is most of what the reader would feel.
    The thread is because the caller may already be inside an event loop:
    Textual runs one, and `asyncio.run` inside a running loop raises rather
    than nesting. A loop of its own is callable from either side.
    """

    def __init__(self, url: str, token: str | None) -> None:
        self._url = url
        self._token = token
        self._headers = {"Authorization": f"Bearer {token}"} if token else None
        self._loop = asyncio.new_event_loop()
        self._session: Any = None
        self._failure: BaseException | None = None
        self._stopping: asyncio.Event | None = None
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        # Long enough for a handshake over a slow link, short enough that a
        # wrong address is an error rather than a hang.
        if not self._ready.wait(timeout=30):
            raise RemoteError(f"{url}: no answer")
        if self._failure is not None:
            raise self._failure

    def call(self, tool: str, arguments: dict[str, Any], timeout: float = 60) -> Any:
        if self._session is None:
            raise RemoteError(f"{self._url}: the session is closed")
        return asyncio.run_coroutine_threadsafe(
            self._session.call_tool(tool, arguments), self._loop
        ).result(timeout)

    def close(self) -> None:
        if self._stopping is not None:
            self._loop.call_soon_threadsafe(self._stopping.set)
        self._thread.join(timeout=5)
        self._session = None

    # ---- on the thread -------------------------------------------------

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._hold())
        finally:
            self._loop.close()
            self._ready.set()

    async def _hold(self) -> None:
        """Open everything, then sit still until told to stop.

        One coroutine holds all three context managers for the session's whole
        life, because anyio's cancel scopes have to be left by the task that
        entered them — unwinding this from `close` on another thread is how
        that rule gets broken.
        """
        self._stopping = asyncio.Event()
        try:
            async with create_mcp_http_client(headers=self._headers) as http:
                async with streamable_http_client(self._url, http_client=http) as (
                    read,
                    write,
                ):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        self._session = session
                        self._ready.set()
                        await self._stopping.wait()
        except BaseException as error:  # noqa: BLE001 — reported to the caller
            self._failure = RemoteError(
                f"{self._url}: {_explain(error, self._token)}"
            )
            self._ready.set()
        finally:
            self._session = None


def _explain(error: BaseException, token: str | None) -> str:
    """What went wrong, in a sentence somebody can act on.

    The transport does not carry the status code up, so a 401 arrives as a flat
    "server returned an error response" whether it happened on the handshake or
    on a call. A refusal is what a missing or wrong token looks like from here,
    and saying so is the difference between a message and a shrug.
    """
    leaf = _leaf(error)
    text = str(leaf) or leaf.__class__.__name__
    if isinstance(leaf, MCPError):
        text += (
            " — check SUMMAREADER_MCP_TOKEN against the mirror's bearer_token"
            if token
            else " — if the mirror sets bearer_token, put it in SUMMAREADER_MCP_TOKEN"
        )
    return text


def _leaf(error: BaseException) -> BaseException:
    """The innermost exception of a group, which is the half that says anything.

    The client runs its transport in a task group, so everything that goes
    wrong arrives as "unhandled errors in a TaskGroup (1 sub-exception)" —
    true, and no use to anyone.
    """
    while isinstance(error, BaseExceptionGroup) and error.exceptions:
        error = error.exceptions[0]
    return error


def _payload(tool: str, result: Any) -> dict[str, Any]:
    """The tool's dict, from wherever this server put it.

    The tools are annotated `-> dict`, which is not specific enough for an
    output schema, so there is no structured content and the dict arrives as
    JSON in a text block. Both are read: a server that grows a schema later
    should not break a client that only knew the old spelling.
    """
    payload = getattr(result, "structured_content", None)
    if isinstance(payload, dict):
        return payload
    text = _text(result)
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        raise RemoteError(f"{tool}: answered with {text[:200]!r}") from None
    if not isinstance(payload, dict):
        raise RemoteError(f"{tool}: answered with {type(payload).__name__}, not an object")
    return payload


def _text(result: Any) -> str:
    parts = [getattr(block, "text", "") for block in getattr(result, "content", [])]
    return " ".join(p for p in parts if p) or "the server said it failed"


def _item(row: dict[str, Any]) -> Item:
    """A row of the tool's JSON, back into the dataclass the front ends read.

    Lossy only where nothing looks: the tools publish a summary's tldr and its
    points, and tldr and points are all `report.py` and the two front ends ever
    read off one.
    """
    tldr = row.get("summary")
    points = [SummaryPoint(text=p) for p in row.get("points") or []]
    return Item(
        id=row["id"],
        title=row.get("title") or "",
        source=row.get("source") or "",
        url=row.get("url") or "",
        published=_when(row.get("published")),
        read=bool(row.get("read")),
        summary=Summary(tldr=tldr or "", points=points) if tldr or points else None,
        words=row.get("words"),
        read_at=_when(row.get("read_at")),
    )


def _when(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None
