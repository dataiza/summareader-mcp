"""Stdio in, HTTP out: the command a desktop agent client can start.

**Most desktop MCP clients are configured with a command to run, and the app
is a window.** This is the command. It reads MCP frames on stdin, posts them
to a running SummaReader's local door, and writes the answers to stdout.

It lives here rather than beside the app because a second compiled executable
has to be signed, notarised, and given a place in three packages — while this
repository is already a thing people install. The app ships no binary for it;
`pipx install summareader-mcp` and the command exists on every platform at
once.

**It holds no library logic at all.** If it ever parses a tool call it has
grown into the wrong thing: the tools are in the app, behind the one token
that guards them, and the whole point of forwarding is that this side does
not have to know what they are.

**stdout is the transport.** A single stray line on it breaks the session, so
everything this says goes to stderr, including every failure.

The port and the token come from the file the app writes beside its library
when the door opens -- never from arguments, and never from the keychain,
which a second process cannot open on macOS without prompting. Drifting from
where the app writes it is how this fails silently inside somebody's client,
so there is one name for that file and both sides use it.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, BinaryIO

import httpx

#: The app's own identifier, which is what names its support directory. Spelled
#: out because nothing here carries Flutter to ask `path_provider` for it.
APP_ID = "sk.dataiza.summareader"

HANDOFF_NAME = "mcp.json"


def default_handoff() -> Path:
    """Where the app writes the door, by the same rules `path_provider` uses.

    The three platforms disagree and none of them is guessable from the other
    two, which is why this is a table rather than a join.
    """
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_ID / HANDOFF_NAME
    if os.name == "nt":
        return Path(os.environ.get("APPDATA", "")) / APP_ID / HANDOFF_NAME
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / APP_ID / HANDOFF_NAME


def read_handoff(path: Path) -> tuple[int, str] | None:
    """The port and the token, or None when the app is not answering.

    None is an ordinary answer rather than an error: the reader closed the
    window, or never switched the door on, and that is what the client has to
    be told.
    """
    try:
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(decoded, dict):
        return None
    port, token = decoded.get("port"), decoded.get("token")
    if not isinstance(port, int) or not isinstance(token, str) or not token:
        return None
    return port, token


def refusal(frame: str, message: str) -> str:
    """A JSON-RPC error carrying the id the client asked with, so it stops
    waiting.

    A frame whose id cannot be read is answered against null, which is what the
    protocol says for a request that could not be understood.
    """
    ident: Any = None
    try:
        decoded = json.loads(frame)
        if isinstance(decoded, dict):
            ident = decoded.get("id")
    except ValueError:
        ident = None
    return json.dumps(
        {
            "jsonrpc": "2.0",
            "id": ident,
            "error": {"code": -32000, "message": message},
        }
    )


def forward(
    url: str,
    token: str,
    stdin: BinaryIO,
    stdout: BinaryIO,
    stderr: Any,
    client: httpx.Client | None = None,
) -> int:
    """The loop. Given streams rather than reaching for `sys`, so a test can
    drive it without a subprocess."""
    owned = client is None
    # No timeout: a tool call may summarize an article, which takes as long as
    # a model takes. The client's own patience is the only sensible limit, and
    # a forwarder that gave up early would look exactly like the app crashing.
    client = client or httpx.Client(timeout=None)
    try:
        # Line-delimited JSON, which is what a stdio client writes: one frame
        # per line. Read as lines so a frame is never split across two posts.
        for raw in stdin:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                response = client.post(
                    url,
                    content=line.encode("utf-8"),
                    headers={
                        "content-type": "application/json",
                        "authorization": f"Bearer {token}",
                    },
                )
            except httpx.HTTPError as error:
                # The window closed mid-session. Said on stderr and answered on
                # stdout, because a client waiting for a reply to an id will
                # otherwise wait for ever.
                print(
                    f"summareader-mcp: the app stopped answering: {error}",
                    file=stderr,
                )
                _write(stdout, refusal(line, "SummaReader is not running"))
                return 1

            if response.status_code == 401:
                print(
                    "summareader-mcp: the app refused the token. It may have "
                    "been rotated — switch the door off and on again.",
                    file=stderr,
                )
                _write(stdout, refusal(line, "SummaReader refused the token"))
                return 1
            if response.status_code == 202 or not response.content:
                # A notification. The protocol answers those with nothing, and
                # writing an empty line here would be a frame the client has to
                # parse.
                continue
            _write(stdout, response.text.strip())
    finally:
        if owned:
            client.close()
    return 0


def _write(stdout: BinaryIO, frame: str) -> None:
    stdout.write(frame.encode("utf-8") + b"\n")
    stdout.flush()
