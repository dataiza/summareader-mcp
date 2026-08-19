"""The desktop window, without a desktop.

Tk needs a display and a build of the interpreter that has it, and neither is
guaranteed on a build machine — so a suite that opened a window would be a
suite that skipped everywhere and caught nothing. The window itself is
therefore a thin shell over plain functions, and this asks those the questions
that go wrong silently: the argv the unit runs, what Start does when systemd
owns the server, which numbers reach the pane, and what the window says when
it is pointed at a mirror it does not hold.

The two tests at the bottom do open a real window, and skip when they cannot.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

from summareader_mcp import gui
from summareader_mcp.config import Config
from summareader_mcp.metrics import Metrics

EXE = ["/home/you/.local/bin/summareader-mcp"]


# ---- the argv, and who runs it -----------------------------------------


def test_the_unit_runs_what_the_window_runs():
    """The whole reason the server is a child process rather than a thread.

    A unit whose ExecStart has drifted from what the window starts is two
    different servers wearing one name — and it fails at the next login, in a
    log nobody has open. Asserting the bytes here is cheaper than installing
    one and reading it back.
    """
    unit = gui.render_unit(
        host="127.0.0.1",
        port=8100,
        config_file="/home/you/.config/summareader-mcp/summareader-mcp.json",
        cache_dir="/home/you/.cache/summareader-mcp",
        exe=EXE,
    )

    argv = " ".join(gui.serve_argv("127.0.0.1", 8100, exe=EXE))
    assert f"ExecStart={argv}\n" in unit
    assert "--transport=http" in argv

    for wanted in (
        (
            'Environment="SUMMAREADER_MCP_CONFIG='
            '/home/you/.config/summareader-mcp/summareader-mcp.json"'
        ),
        'Environment="SUMMAREADER_MCP_CACHE=/home/you/.cache/summareader-mcp"',
        "ReadWritePaths=/home/you/.cache/summareader-mcp",
        "WantedBy=default.target",
    ):
        assert wanted in unit, unit

    # And what the window reads back on the next launch, so it reopens on the
    # server that is running rather than on its own defaults.
    assert gui.unit_bind(unit) == ("127.0.0.1", 8100)


def test_a_unit_owns_the_server_and_the_window_only_asks_it():
    """One owner at a time.

    With a unit installed, a window that started a child of its own would put
    a second server on one library: both pulling, both advancing the same
    cursor, and the second one failing to bind — which from the window reads
    as "Start did nothing".
    """
    managed = gui.start_command(managed=True, host="127.0.0.1", port=8100, exe=EXE)
    assert managed == ["systemctl", "--user", "start", "summareader-mcp.service"]
    assert EXE[0] not in managed

    alone = gui.start_command(managed=False, host="127.0.0.1", port=8100, exe=EXE)
    assert alone == gui.serve_argv("127.0.0.1", 8100, exe=EXE)


def test_the_unit_is_looked_for_where_systemd_looks(tmp_path: Path):
    environment = {"XDG_CONFIG_HOME": str(tmp_path)}
    path = gui.unit_path(environment)
    assert path == tmp_path / "systemd/user/summareader-mcp.service"

    assert not gui.service_installed(environment)
    path.parent.mkdir(parents=True)
    path.write_text("[Unit]\n")
    assert gui.service_installed(environment) == sys.platform.startswith("linux")


# ---- the numbers -------------------------------------------------------


def test_the_scraper_reads_a_named_mirrors_metrics_too():
    """`Metrics.render` labels every sample as soon as a name is configured.

    A parser matching only a bare name would read every number as missing on
    exactly the installations that bothered to name themselves — and a pane
    showing "0 pulls" for ever looks like a server that has never synced.
    """
    text = (
        "# TYPE summareader_mcp_pulls_total counter\n"
        'summareader_mcp_pulls_total{instance="MCP mirror"} 14\n'
        'summareader_mcp_pull_failures_total{instance="MCP mirror"} 2\n'
        'summareader_mcp_last_pull_age_seconds{instance="MCP mirror"} 240\n'
    )
    assert gui.scrape(text) == {"pulls": 14.0, "failures": 2.0, "last_pull_age": 240.0}

    bare = "summareader_mcp_pulls_total 3\n"
    assert gui.gauge(bare, "summareader_mcp_pulls_total") == 3.0

    # A longer name that merely starts the same way is a different metric, and
    # reading it as this one is a wrong number rather than a missing one.
    assert gui.gauge("summareader_mcp_items_summarized 7\n",
                     "summareader_mcp_items") is None
    assert gui.gauge("", "summareader_mcp_items") is None


def test_the_pane_shows_what_the_library_holds_and_how_the_syncing_went():
    counts = {"items": 1284, "unread": 37, "summarized": 1190,
              "bodies": 1102, "sources": 9}
    shown = dict(gui.format_stats(counts, "418", {"failures": 0, "last_pull_age": 90}))

    assert shown["Articles"] == "1284"
    assert shown["Unread"] == "37"
    assert shown["Summarized"] == "1190"
    assert shown["With text"] == "1102"
    assert shown["Sources"] == "9"
    assert shown["Cursor"] == "418"
    assert shown["Last pull"] == "1 minute ago"
    # Nought failures is the reassurance and has to be printed; a blank there
    # reads as "not measured", which is what an unreachable server means.
    assert shown["Failures"] == "0"

    nothing = dict(gui.format_stats({}, None))
    assert nothing["Articles"] == "0"
    assert nothing["Cursor"] == "0"
    assert nothing["Last pull"] == "never"
    assert nothing["Failures"] == "—"


def test_a_pull_from_the_window_still_shows_when_no_server_is_up():
    """The window keeps its own Metrics for exactly this.

    Pull now works with the server stopped, and the pane would otherwise go on
    saying "never" straight after a pull that visibly happened.
    """
    metrics = Metrics()
    assert gui.from_metrics(metrics)["last_pull_age"] is None

    metrics.pulled(ok=False)
    seen = gui.from_metrics(metrics)
    assert seen["pulls"] == 1 and seen["failures"] == 1
    assert gui.ago(seen["last_pull_age"]) == "just now"


def test_how_long_ago_is_said_in_terms_somebody_reads():
    assert gui.ago(None) == "never"
    assert gui.ago(12) == "just now"
    assert gui.ago(600) == "10 minutes ago"
    assert gui.ago(7200) == "2 hours ago"
    assert gui.ago(90) == "1 minute ago"  # never "1 minutes"
    assert gui.ago(400000) == "4 days ago"


# ---- what the window refuses -------------------------------------------


def test_a_remote_mirror_is_read_and_not_driven():
    """`--remote` is a reader with no library of its own.

    Search and the counts are what it is for; Start, Stop and Pull belong to
    the machine holding the library. Said in a sentence rather than by three
    greyed-out buttons, the way cli.py refuses `serve` under `--remote`.
    """
    said = gui.refusal(remote="http://box:8100")
    assert said and "http://box:8100" in said
    for word in ("Start", "Stop", "Pull"):
        assert word in said

    reading = gui.refusal(library=Path("/home/you/library.sqlite"))
    assert reading and "read-only" in reading

    assert gui.refusal() is None


def test_the_status_line_says_who_is_running_it():
    assert gui.status_line(running=True, url="http://127.0.0.1:8100", managed=True) == (
        "Running on http://127.0.0.1:8100 (systemd)"
    )
    assert gui.status_line(
        running=True, url="http://127.0.0.1:8100", managed=False
    ) == "Running on http://127.0.0.1:8100"
    assert gui.status_line(
        running=False, url="http://127.0.0.1:8100", managed=False
    ).startswith("Not running")


def test_the_window_asks_an_address_it_can_actually_reach():
    """0.0.0.0 is a decision about what to accept, not a place to connect to.

    A server bound there is up and answering, and a window polling
    http://0.0.0.0:8100 shows it as down on some stacks and hangs on others.
    """
    assert gui.reachable("0.0.0.0", 8100) == "http://127.0.0.1:8100"
    assert gui.reachable("::", 8100) == "http://127.0.0.1:8100"
    assert gui.reachable("192.168.1.24", 8100) == "http://192.168.1.24:8100"
    assert gui.reachable("::1", 8100) == "http://[::1]:8100"


def test_the_supervisor_never_spawns_a_child_when_a_unit_owns_the_server(monkeypatch):
    """The same rule as start_command, asserted at the seam that could break it.

    Popen here would be the second server; the test that would notice is this
    one, because nothing else can tell the difference until the library is
    already being written by two processes.
    """
    called: list[tuple] = []
    monkeypatch.setattr(gui, "systemctl", lambda *args: called.append(args))
    monkeypatch.setattr(
        gui.subprocess, "Popen", lambda *a, **k: pytest.fail("started a second server")
    )

    supervisor = gui.Supervisor(Config.for_library("/tmp/x.sqlite"), "/tmp/c.json",
                                "127.0.0.1", 8100)
    monkeypatch.setattr(type(supervisor), "managed", property(lambda _: True))

    supervisor.start()
    supervisor.stop()
    assert called == [("start", "summareader-mcp.service"), ("stop",
                      "summareader-mcp.service")]


# ---- and the window itself, when there is somewhere to draw it ----------


@pytest.fixture
def window(tmp_path: Path, monkeypatch):
    tk = pytest.importorskip("tkinter", reason="no Tk in this interpreter")
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        pytest.skip("no display")
    try:
        root = tk.Tk()
    except tk.TclError as error:  # a display that exists and will not have us
        pytest.skip(str(error))
    root.withdraw()

    # Every worker inline, so the test is over when the last assert is rather
    # than whenever a thread gets round to it. Threads left running past
    # root.destroy() are a Tcl interpreter being called from nowhere, which is
    # a crash in whichever test happens to be running by then.
    monkeypatch.setattr(
        gui.Window, "_off_thread",
        lambda self, work, done=None: self._finish(work(), done),
    )

    from tkinter import ttk

    from summareader_mcp.store import open_store

    store = open_store(tmp_path / "library.sqlite")
    config = Config.for_library(tmp_path / "library.sqlite")
    try:
        yield gui.Window(root, tk, ttk, config, tmp_path / "c.json", store,
                         "127.0.0.1", 8100)
    finally:
        store.close()
        root.destroy()


def test_it_draws_and_leaves_the_buttons_off_for_a_library_it_does_not_own(window):
    assert window.status.cget("text")
    assert window.local is False
    assert window.supervisor is None
    for button in (window.start, window.stop, window.pull):
        assert "disabled" in button.state()
    # No checkbox at all in this mode: there is nothing to install a unit for.
    assert window.at_login is None


def test_searching_an_empty_library_says_so_rather_than_hanging(window):
    window._show_results([])
    assert window.message.cget("text") == "0 matching"
    assert window.results.get_children() == ()


class TestClosingTheWindow:
    def test_a_child_started_here_dies_here(self):
        # Otherwise it holds the port and the library after the window is
        # gone, and the next Start fails to bind.
        class Child:
            managed = False
            stopped = False

            def stop(self):
                self.stopped = True

        child = Child()
        gui.stop_on_close(child)
        assert child.stopped

    def test_a_service_is_left_alone(self):
        # Outliving the window is the whole reason somebody installed a unit.
        class Service:
            managed = True
            stopped = False

            def stop(self):
                self.stopped = True

        service = Service()
        gui.stop_on_close(service)
        assert not service.stopped

    def test_a_window_with_nothing_to_supervise_closes_quietly(self):
        # --remote and --library never build one.
        gui.stop_on_close(None)
