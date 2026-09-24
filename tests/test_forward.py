"""The forwarder: stdin to a door, the door's answers to stdout.

Driven against a real socket rather than a mocked client, because every bug
this has had lives in the seam — a notification answered with a blank line, a
refused connection that hangs, a token header spelled the way the app does not
read it.
"""

from __future__ import annotations

import io
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from summareader_mcp.forward import (
    default_handoff,
    forward,
    read_handoff,
    refusal,
)


class _Door:
    """A stand-in for the app's `POST /mcp`, answering the way it does."""

    def __init__(self, token: str = "sesame"):
        self.token = token
        self.seen: list[dict] = []
        self.headers: list[str] = []
        door = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):  # keep the test output quiet
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["content-length"]))
                frame = json.loads(body)
                door.seen.append(frame)
                door.headers.append(self.headers.get("authorization", ""))
                if self.headers.get("authorization") != f"Bearer {door.token}":
                    self.send_response(401)
                    self.end_headers()
                    return
                if "id" not in frame:
                    # A notification, answered the way the app answers one.
                    self.send_response(202)
                    self.end_headers()
                    return
                answer = json.dumps(
                    {"jsonrpc": "2.0", "id": frame["id"], "result": {"ok": True}}
                ).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(answer)))
                self.end_headers()
                self.wfile.write(answer)

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}/mcp"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def door():
    d = _Door()
    yield d
    d.close()


def _run(door, frames, token="sesame"):
    out, err = io.BytesIO(), io.StringIO()
    code = forward(
        door.url, token, io.BytesIO("\n".join(frames).encode()), out, err
    )
    return code, out.getvalue().decode(), err.getvalue()


def test_a_request_is_carried_there_and_its_answer_back(door):
    code, out, _ = _run(door, ['{"jsonrpc":"2.0","id":1,"method":"tools/list"}'])
    assert code == 0
    assert door.seen == [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
    assert json.loads(out) == {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}


def test_the_token_goes_in_the_header_the_app_reads(door):
    _run(door, ['{"jsonrpc":"2.0","id":1,"method":"ping"}'])
    assert door.headers == ["Bearer sesame"]


def test_a_notification_puts_nothing_on_stdout(door):
    # 202 and no body. A blank line here is a frame the client has to parse,
    # and it is the one that breaks a session for no visible reason.
    code, out, _ = _run(door, ['{"jsonrpc":"2.0","method":"notifications/initialized"}'])
    assert code == 0
    assert out == ""


def test_one_frame_per_line_and_blank_lines_are_skipped(door):
    code, out, _ = _run(
        door,
        [
            '{"jsonrpc":"2.0","id":1,"method":"a"}',
            "",
            '{"jsonrpc":"2.0","id":2,"method":"b"}',
        ],
    )
    assert code == 0
    assert [f["id"] for f in door.seen] == [1, 2]
    assert [json.loads(l)["id"] for l in out.splitlines()] == [1, 2]


def test_a_refused_token_is_said_on_stderr_and_answered_on_stdout(door):
    code, out, err = _run(door, ['{"jsonrpc":"2.0","id":7,"method":"a"}'], token="wrong")
    assert code == 1
    assert "refused the token" in err
    # Answered, not merely logged: a client waiting on id 7 otherwise waits
    # for ever.
    assert json.loads(out)["id"] == 7
    assert json.loads(out)["error"]["code"] == -32000


def test_a_closed_window_answers_the_pending_id_rather_than_hanging():
    door = _Door()
    url = door.url
    door.close()
    out, err = io.BytesIO(), io.StringIO()
    code = forward(
        url, "sesame", io.BytesIO(b'{"jsonrpc":"2.0","id":9,"method":"a"}\n'), out, err
    )
    assert code == 1
    assert "stopped answering" in err.getvalue()
    assert json.loads(out.getvalue())["id"] == 9


def test_stdout_carries_nothing_but_frames(door):
    # stdout is the transport. Every line on it must parse as JSON-RPC.
    _, out, _ = _run(door, ['{"jsonrpc":"2.0","id":1,"method":"a"}'])
    for line in out.splitlines():
        assert json.loads(line)["jsonrpc"] == "2.0"


def test_a_frame_with_an_unreadable_id_is_refused_against_null():
    assert json.loads(refusal("not json at all", "no"))["id"] is None


def test_the_handoff_is_read_and_a_missing_one_is_an_ordinary_none(tmp_path: Path):
    good = tmp_path / "mcp.json"
    good.write_text(json.dumps({"port": 8767, "token": "t"}))
    assert read_handoff(good) == (8767, "t")
    assert read_handoff(tmp_path / "nothing.json") is None


@pytest.mark.parametrize(
    "content",
    ["{}", '{"port":"8767","token":"t"}', '{"port":8767,"token":""}', "[]", "{"],
)
def test_a_handoff_that_says_too_little_is_none(tmp_path: Path, content: str):
    path = tmp_path / "mcp.json"
    path.write_text(content)
    assert read_handoff(path) is None


def test_the_default_handoff_is_where_the_app_writes_it(monkeypatch):
    # The app's own id. If this and the app disagree the forwarder looks in an
    # empty directory and says the app is not running, which is the failure
    # nobody thinks to check.
    monkeypatch.setenv("XDG_DATA_HOME", "/tmp/xdg")
    if os.name != "nt":
        path = default_handoff()
        assert path.name == "mcp.json"
        assert "sk.dataiza.summareader" in str(path)


def test_the_command_itself_carries_a_frame(door, tmp_path: Path):
    """The whole thing as a client starts it: a process, a pipe, a handoff file.

    Driving `forward` directly misses everything the command adds — the
    subcommand, reading the file, and the raw buffers. That seam is where the
    Dart original's worst bug lived (a failure exit that reported success), so
    it is worth a real process.
    """
    import subprocess
    import sys as _sys

    handoff = tmp_path / "mcp.json"
    handoff.write_text(
        json.dumps({"port": door.server.server_port, "token": "sesame"})
    )
    result = subprocess.run(
        [
            _sys.executable,
            "-m",
            "summareader_mcp",
            "forward",
            "--handoff",
            str(handoff),
        ],
        input=b'{"jsonrpc":"2.0","id":3,"method":"tools/list"}\n',
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr.decode()
    assert json.loads(result.stdout)["id"] == 3
    # stdout is the transport: nothing but the frame may reach it.
    assert result.stdout.decode().count("\n") == 1
