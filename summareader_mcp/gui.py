"""The mirror in a window, for the machine that holds the library.

The fourth way in, after the MCP server, the terminal interface and the
command line. It exists for the two steps that were terminal-only and had no
business being so: keeping the thing running, and searching what it holds.

# Tkinter

From the standard library, and that is the whole argument. This gets frozen
into one executable by scripts/freeze.sh, and every toolkit that is not
already in the interpreter is another hundred and fifty megabytes in the
download and another set of platform libraries to bundle correctly. A window
with six controls on it does not earn that.

# The server is a child, not this process

`serve` blocks, holds the master key and is restarted by the person at the
keyboard; running it inside the window would mean an unhandled traceback in
the sync loop taking the window down with it, and would mean the desktop path
and the systemd path being two different pieces of code that drift apart. So
the window starts exactly the argv the unit's ExecStart line holds — see
`render_unit`, which is asserted against `serve_argv` in the tests for that
reason.

# One owner at a time

With a user unit installed, that unit owns the server and this window is a
remote control for it: Start and Stop drive `systemctl --user`, and the window
never starts a child of its own. Two servers on one library would both pull,
both advance the same cursor and both hold the port — and the second one
simply fails to bind, which reads from here as "Start did nothing".

# Where the numbers come from

Counts come out of the library file, which this window already has open for
the search box; SQLite is in WAL with a busy timeout precisely so a reader and
a writer can coexist, which `serve` and `ui` have always relied on. What is
*not* in the file is how the running process is getting on — pulls, failures,
how long since the last one — because that lives in `Metrics` in its memory.
So that half is scraped from the server's own /metrics over its port, with the
configured bearer token, and /health is what "is it up" means.
"""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from .config import Config, default_config_path
from .metrics import Metrics
from .store import Item, open_store
from .store.remote import RemoteStore

UNIT_NAME = "summareader-mcp.service"

#: How often the window asks the server how it is. Two seconds is what a
#: status light has to be to read as a status light rather than as a log.
POLL_SECONDS = 2.0


# ---- what the window knows, with no toolkit involved --------------------
#
# Everything below is a plain function of its arguments, because a window is
# the one part of a program a test cannot look at. The argv, the unit file and
# the numbers are the parts that are wrong silently — a bad ExecStart is a
# service that fails at the next login in a log nobody has open — so they are
# asserted here rather than by installing one and hoping.


def launcher() -> list[str]:
    """How to start another copy of this program.

    A frozen bundle is its own interpreter and has no package to import; a
    checkout has an interpreter and no console script until it is installed.
    `python -m` covers the second without depending on a shim that a venv may
    or may not have generated, and sys.executable is absolute in both, which
    is what a unit's ExecStart needs.
    """
    if getattr(sys, "frozen", False):
        return [sys.executable]
    return [sys.executable, "-m", "summareader_mcp"]


def serve_argv(host: str, port: int, *, exe: list[str] | None = None) -> list[str]:
    """The one spelling of "run the server", shared by the window and the unit.

    HTTP rather than stdio: a supervised server has no MCP client on the other
    end of its standard input, and the window itself needs the port to ask it
    anything.
    """
    return [*(exe or launcher()), "serve", "--transport=http",
            f"--host={host}", f"--port={port}"]


def start_command(
    *, managed: bool, host: str, port: int, exe: list[str] | None = None
) -> list[str]:
    """What Start runs — which depends entirely on who owns the server.

    With a unit installed the answer is systemctl and never a child of our
    own: see the note about one owner at the top of this file.
    """
    if managed:
        return ["systemctl", "--user", "start", UNIT_NAME]
    return serve_argv(host, port, exe=exe)


def unit_path(environment: dict[str, str] | None = None) -> Path:
    """Where systemd looks. XDG_CONFIG_HOME is honoured because systemd does."""
    env = dict(os.environ if environment is None else environment)
    base = Path(env.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "systemd" / "user" / UNIT_NAME


def render_unit(
    *,
    host: str,
    port: int,
    config_file: Path | str,
    cache_dir: Path | str,
    exe: list[str] | None = None,
) -> str:
    """The unit file, as a pure function of what the window was asked for.

    The same unit scripts/summareader-mcp.service describes, written from the
    window so that somebody who has an executable and no repository can still
    have the thing come back after a reboot. A *user* unit, for the reason the
    script gives: this holds the master key and a plaintext copy of somebody's
    library, so it belongs to one person and needs no root to inspect or
    remove.

    Environment values are quoted because a cache directory with a space in it
    is unremarkable on a desktop, and unquoted it would silently become two
    variables, one of them empty.
    """
    return f"""[Unit]
# Written by the SummaReader mirror's window. Turning off "Start at login"
# there removes this file again.
Description=SummaReader MCP server
Documentation=https://github.com/dataiza/summareader-mcp
After=network-online.target
Wants=network-online.target

[Service]
ExecStart={" ".join(serve_argv(host, port, exe=exe))}
Environment="SUMMAREADER_MCP_CONFIG={config_file}"
Environment="SUMMAREADER_MCP_CACHE={cache_dir}"
Restart=on-failure
RestartSec=5

# This process holds the master key and a plaintext copy of the library — the
# one place in the design where the encryption ends. Everything it does not
# need to touch is closed off.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths={cache_dir}

[Install]
WantedBy=default.target
"""


def unit_bind(unit: str) -> tuple[str, int] | None:
    """The address an installed unit serves on.

    So a window opened later reopens on the server that is actually running
    rather than on its own defaults — which would otherwise show a healthy
    server as down, on a port nothing answers.
    """
    host = port = None
    for word in unit.split():
        if word.startswith("--host="):
            host = word.removeprefix("--host=").strip('"')
        elif word.startswith("--port="):
            port = word.removeprefix("--port=").strip('"')
    if host is None or port is None:
        return None
    try:
        return host, int(port)
    except ValueError:
        return None


def service_installed(environment: dict[str, str] | None = None) -> bool:
    """Whether a unit exists, which is the same question as who owns the server."""
    return sys.platform.startswith("linux") and unit_path(environment).exists()


def systemctl(*args: str) -> None:
    """One command against the user manager, raising what it said when it failed.

    "exit status 1" in a status line tells nobody anything, and this is the
    one place in the window where the failure is somebody else's to fix.
    """
    done = subprocess.run(
        ["systemctl", "--user", *args], capture_output=True, text=True, check=False
    )
    if done.returncode != 0:
        said = (done.stderr or done.stdout).strip()
        raise RuntimeError(said or f"systemctl --user {' '.join(args)} failed")


def install_service(unit: str, environment: dict[str, str] | None = None) -> None:
    """Write the unit and enable it. Writing over an existing one is the update
    path: a port changed in the window has to reach the unit too, or the
    service comes back on the old one."""
    path = unit_path(environment)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(unit, encoding="utf-8")
    systemctl("daemon-reload")
    systemctl("enable", "--now", UNIT_NAME)


def uninstall_service(environment: dict[str, str] | None = None) -> None:
    # Disable before removing: the enable symlink outlives the unit file and
    # leaves systemd complaining about it at every login.
    try:
        systemctl("disable", "--now", UNIT_NAME)
    except (RuntimeError, FileNotFoundError):
        pass
    unit_path(environment).unlink(missing_ok=True)
    systemctl("daemon-reload")


def gauge(text: str, name: str) -> float | None:
    """One sample out of the Prometheus text format, labelled or not.

    Labelled matters here: `Metrics.render` puts `{instance="…"}` on every
    sample as soon as a name is configured, so a parser that only matched a
    bare name would read every number as absent on exactly the installations
    that bothered to name themselves.

    A dozen lines rather than a Prometheus client dependency, for ten lines of
    output that this program also writes.
    """
    for line in text.splitlines():
        if not line.startswith(name):
            continue
        rest = line[len(name):]
        if rest.startswith("{"):
            rest = rest.partition("}")[2]
        elif not rest.startswith(" "):
            continue  # a longer metric name that merely starts the same way
        try:
            return float(rest.strip())
        except ValueError:
            return None
    return None


def scrape(text: str) -> dict[str, float | None]:
    """The part of the picture that only the running process knows."""
    return {
        "pulls": gauge(text, "summareader_mcp_pulls_total"),
        "failures": gauge(text, "summareader_mcp_pull_failures_total"),
        "last_pull_age": gauge(text, "summareader_mcp_last_pull_age_seconds"),
    }


def from_metrics(metrics: Metrics) -> dict[str, float | None]:
    """The same three numbers, when this window did the pulling itself."""
    return {
        "pulls": float(metrics.pulls),
        "failures": float(metrics.failures),
        "last_pull_age": (
            None if metrics.last_pull is None else time.time() - metrics.last_pull
        ),
    }


def ago(seconds: float | None) -> str:
    """How long ago, in the roughest terms that are still true.

    Nobody reads a status pane for a figure in seconds, and a pull that
    happened 4,812 seconds ago is a sentence the reader has to do arithmetic
    on before it means anything.
    """
    if seconds is None:
        return "never"
    if seconds < 90:
        return "just now"
    if seconds < 3600:
        return _ago(seconds // 60, "minute")
    if seconds < 172800:
        return _ago(seconds // 3600, "hour")
    return _ago(seconds // 86400, "day")


def _ago(count: float, noun: str) -> str:
    """Two words of English rather than a pluralisation library, for the three
    nouns this pane ever counts."""
    return f"{int(count)} {noun}{'' if int(count) == 1 else 's'} ago"


def format_stats(
    counts: dict[str, int],
    cursor: str | int | None,
    scraped: dict[str, float | None] | None = None,
) -> list[tuple[str, str]]:
    """The stats pane, as label-and-value pairs.

    A list of pairs rather than a formatted block, so the same numbers can be
    laid out as a grid and asserted in a test without parsing a paragraph
    back apart.
    """
    scraped = scraped or {}
    failures = scraped.get("failures")
    return [
        ("Articles", str(counts.get("items", 0))),
        ("Unread", str(counts.get("unread", 0))),
        ("Summarized", str(counts.get("summarized", 0))),
        ("With text", str(counts.get("bodies", 0))),
        ("Sources", str(counts.get("sources", 0))),
        ("Cursor", str(int(cursor or 0))),
        ("Last pull", ago(scraped.get("last_pull_age"))),
        # Zero failures is worth printing rather than hiding: "0" is the
        # reassurance, and a blank line reads as "not measured".
        ("Failures", "—" if failures is None else str(int(failures))),
    ]


def refusal(*, remote: str | None = None, library=None) -> str | None:
    """Why half the window is greyed out, in a sentence rather than by silence.

    `--remote` is a reader with no library of its own. Searching one and
    reading its counts is exactly what it is for; starting, stopping and
    pulling are things only the machine holding the library can do, and this
    process is not it. `--library` is the other half of the same shape: a file
    the app owns, opened read-only, with no sync server behind it to pull from.

    Said in a sentence for the same reason `cli.py` says it in a sentence when
    `serve` is asked for over `--remote` — a greyed-out button explains
    nothing, and the reader is left wondering what they broke.
    """
    if remote:
        return (
            f"Reading the mirror at {remote}. Search and the counts are its "
            "answers; Start, Stop and Pull belong to the machine that holds "
            "the library, so they are off here."
        )
    if library:
        return (
            f"Reading {library} directly, read-only. There is nothing to "
            "start and nothing to pull: the app owns this file and keeps it "
            "up to date itself."
        )
    return None


def status_line(*, running: bool, url: str, managed: bool) -> str:
    if not running:
        return f"Not running — {url}"
    return f"Running on {url}" + (" (systemd)" if managed else "")


def reachable(host: str, port: int) -> str:
    """The address to *ask*, which is not always the address bound.

    0.0.0.0 and :: are decisions about what to accept, not places to connect
    to; asking them is a connection refused on some stacks and a surprise on
    others.
    """
    if host in ("0.0.0.0", "", "::", "*"):
        host = "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"http://{host}:{port}"


def _get(url: str, token: str | None, timeout: float = 2.0) -> str | None:
    request = urllib.request.Request(url)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read(1 << 20).decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, ValueError):
        # A server that is down is not an error to report; it is the thing the
        # status line is there to say, and this runs every two seconds.
        return None


# ---- the server this window supervises ---------------------------------


class Supervisor:
    """The server, whoever happens to own it.

    Holds a child process when it started one, and holds nothing at all when a
    unit is installed — in which case every method here is a systemctl call.
    """

    def __init__(
        self, config: Config, config_file: Path | str, host: str, port: int
    ) -> None:
        self._config = config
        self._config_file = config_file
        self.host, self.port = host, port
        self._child: subprocess.Popen | None = None

    @property
    def managed(self) -> bool:
        return service_installed()

    @property
    def url(self) -> str:
        return reachable(self.host, self.port)

    def running(self) -> bool:
        if self.managed:
            return (
                subprocess.run(
                    ["systemctl", "--user", "is-active", "--quiet", UNIT_NAME],
                    capture_output=True,
                    check=False,
                ).returncode
                == 0
            )
        return self._child is not None and self._child.poll() is None

    def healthy(self) -> bool:
        """What the port says, which is the only answer that counts.

        A process that is up but has not bound yet, or one somebody else
        started, are both cases where "is there a child" is the wrong question.
        /health needs no credential on purpose.
        """
        return _get(f"{self.url}/health", None) is not None

    def start(self) -> None:
        command = start_command(managed=self.managed, host=self.host, port=self.port)
        if self.managed:
            # `systemctl --user` is the first two words of it; systemctl() puts
            # them back. Asked of start_command either way, so the test that
            # says a unit is never bypassed is asking the code that runs.
            systemctl(*command[2:])
            return
        if self.running():
            return
        # The config file and cache the window is reading are the ones the
        # child must read, or it mirrors into a different library than the one
        # in the search box below it.
        environment = dict(os.environ)
        environment["SUMMAREADER_MCP_CONFIG"] = str(self._config_file)
        environment["SUMMAREADER_MCP_CACHE"] = str(self._config.cache_dir)
        self._child = subprocess.Popen(command, env=environment)

    def stop(self) -> None:
        if self.managed:
            systemctl("stop", UNIT_NAME)
            return
        child = self._child
        if child is None or child.poll() is not None:
            return
        # Terminate first, so the server closes the library instead of being
        # cut off mid-write. A server that ignores it has to be killed anyway,
        # so both roads end at kill.
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()

    def scraped(self) -> dict[str, float | None] | None:
        text = _get(f"{self.url}/metrics", self._config.bearer_token)
        return None if text is None else scrape(text)


def stop_on_close(supervisor: Supervisor | None) -> None:
    """What closing the window does to the server.

    A child this window started dies with it: left running it holds the port
    and the library with nothing on screen admitting to it, and the next
    window's Start fails to bind — which reads from there as "Start did
    nothing", the failure this file is most careful about elsewhere.

    A server systemd owns is emphatically not ours to stop. Outliving the
    window is the entire point of installing the unit.
    """
    if supervisor is None or supervisor.managed:
        return
    supervisor.stop()


# ---- the window --------------------------------------------------------


def run_gui(config: Config, config_file: Path | str, host: str, port: int) -> int:
    """Open the window. Everything above this line runs without a display."""
    import tkinter as tk
    from tkinter import ttk

    store = (
        RemoteStore(config.remote, token=config.bearer_token)
        if config.remote
        else open_store(config.database, read_only=config.reads_a_local_library)
    )
    window = None
    try:
        root = tk.Tk()
        window = Window(root, tk, ttk, config, Path(config_file), store, host, port)
        root.mainloop()
    finally:
        # A child this window started dies with it. Left running it would hold
        # the port and the library with nothing on screen saying so, and the
        # next window's Start would fail to bind — which reads from there as
        # "Start did nothing", the one failure this file is most careful about
        # elsewhere. A server systemd owns is emphatically not ours to stop:
        # the whole point of installing the unit is that it outlives the window.
        stop_on_close(getattr(window, "supervisor", None))
        store.close()
    return 0


class Window:
    """The widgets, and nothing that is worth testing.

    Tk owns its thread: every widget here is touched from the main loop and
    from nowhere else. Anything that blocks — a pull, a systemctl call, a
    request to a server that may not be listening — runs on a worker and comes
    back through `after`, because a status pane that freezes the window while
    it polls is worse than no status pane.
    """

    def __init__(self, root, tk, ttk, config, config_file, store, host, port) -> None:
        self.root, self.tk, self.ttk = root, tk, ttk
        self.config, self.config_file, self.store = config, config_file, store
        self.metrics = Metrics()
        self.local = config.remote is None and not config.reads_a_local_library
        self.supervisor = (
            Supervisor(config, config_file, host, port) if self.local else None
        )

        # A unit already on disk knows where the server is; the window's own
        # defaults do not, and opening on them shows a running server as down.
        if self.supervisor and self.supervisor.managed:
            installed = unit_bind(unit_path().read_text(encoding="utf-8"))
            if installed:
                self.supervisor.host, self.supervisor.port = installed

        root.title("SummaReader mirror")
        root.minsize(720, 620)
        root.geometry("820x700")
        self._build()
        self._poll()

    # ---- layout ---------------------------------------------------------

    def _build(self) -> None:
        ttk, tk = self.ttk, self.tk
        frame = ttk.Frame(self.root, padding=12)
        frame.pack(fill="both", expand=True)
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(5, weight=1)

        self.status = ttk.Label(frame, text="…", font=("TkDefaultFont", 11, "bold"))
        self.status.grid(row=0, column=0, sticky="w")

        note = refusal(remote=self.config.remote, library=self.config.library)
        if note:
            ttk.Label(frame, text=note, wraplength=680, foreground="#a05000").grid(
                row=1, column=0, sticky="w", pady=(4, 0)
            )

        stats = ttk.LabelFrame(frame, text="Library", padding=8)
        stats.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        self.stat_values: dict[str, object] = {}
        for column, (label, _) in enumerate(format_stats({}, 0)):
            stats.columnconfigure(column, weight=1)
            value = ttk.Label(stats, text="—", font=("TkDefaultFont", 13))
            value.grid(row=0, column=column, sticky="w")
            ttk.Label(stats, text=label, foreground="#707070").grid(
                row=1, column=column, sticky="w"
            )
            self.stat_values[label] = value

        buttons = ttk.Frame(frame)
        buttons.grid(row=3, column=0, sticky="ew", pady=(10, 0))
        self.start = ttk.Button(buttons, text="Start", command=self._start)
        self.stop = ttk.Button(buttons, text="Stop", command=self._stop)
        self.pull = ttk.Button(buttons, text="Pull now", command=self._pull)
        for widget in (self.start, self.stop, self.pull):
            widget.pack(side="left", padx=(0, 6))
            if not self.local:
                widget.state(["disabled"])

        # Linux only, and absent rather than greyed out elsewhere: systemd is
        # what this checkbox writes, and a control that cannot work anywhere on
        # this machine is worse than no control at all.
        if self.local and sys.platform.startswith("linux"):
            self.at_login = tk.BooleanVar(value=service_installed())
            ttk.Checkbutton(
                buttons,
                text="Start at login",
                variable=self.at_login,
                command=self._toggle_service,
            ).pack(side="left", padx=(12, 0))
        else:
            self.at_login = None

        # The config file, because editing JSON by hand is the other step that
        # only a terminal could do, and knowing which file to edit is most of
        # it. Read-only text: a window that writes somebody's master key back
        # out is a window that can lose it.
        where = ttk.LabelFrame(frame, text="Configuration", padding=8)
        where.grid(row=4, column=0, sticky="ew", pady=(10, 0))
        where.columnconfigure(1, weight=1)
        rows = [
            ("File", str(self.config_file)),
            ("Library", self.config.remote or str(self.config.database)),
            ("Sync server", self.config.server or "—"),
            ("Name", self.config.name or "(unset)"),
            (
                "Bearer token",
                "set" if self.config.bearer_token else "none — the port is open",
            ),
        ]
        for row, (label, value) in enumerate(rows):
            ttk.Label(where, text=label, foreground="#707070").grid(
                row=row, column=0, sticky="w", padx=(0, 10)
            )
            entry = ttk.Entry(where)
            entry.insert(0, value)
            entry.state(["readonly"])
            entry.grid(row=row, column=1, sticky="ew")

        found = ttk.LabelFrame(frame, text="Search", padding=8)
        found.grid(row=5, column=0, sticky="nsew", pady=(10, 0))
        found.columnconfigure(0, weight=1)
        found.rowconfigure(1, weight=1)

        self.query = ttk.Entry(found)
        self.query.grid(row=0, column=0, sticky="ew")
        self.query.bind("<Return>", lambda _: self._search())
        ttk.Button(found, text="Search", command=self._search).grid(
            row=0, column=1, padx=(6, 0)
        )

        self.results = ttk.Treeview(
            found, columns=("date", "source", "title"), show="headings", height=10
        )
        for column, heading, width in (
            ("date", "Date", 90),
            ("source", "Source", 160),
            ("title", "Title", 420),
        ):
            self.results.heading(column, text=heading)
            self.results.column(column, width=width, anchor="w")
        self.results.grid(row=1, column=0, columnspan=2, sticky="nsew", pady=(8, 0))
        scroll = ttk.Scrollbar(found, orient="vertical", command=self.results.yview)
        self.results.configure(yscrollcommand=scroll.set)
        scroll.grid(row=1, column=2, sticky="ns", pady=(8, 0))

        self.message = ttk.Label(frame, text="", foreground="#707070")
        self.message.grid(row=6, column=0, sticky="w", pady=(8, 0))

        self._search()

    # ---- work off the main thread ---------------------------------------

    def _off_thread(self, work, done=None) -> None:
        """Run `work` on a worker and hand the result back through `after`.

        Tk is not thread-safe and says so by crashing somewhere else entirely,
        so no widget is touched from the worker — the result comes back to the
        main loop and is drawn there.
        """

        def run() -> None:
            try:
                result = work()
            except Exception as error:  # noqa: BLE001 — it reaches the status line
                result = error
            try:
                self.root.after(0, lambda: self._finish(result, done))
            except self.tk.TclError:
                # The window was closed while this was in flight. Handing a
                # result to a destroyed interpreter is not an error to report,
                # it is a segfault a moment later — Tcl has no widget left to
                # raise anything at.
                pass

        threading.Thread(target=run, daemon=True).start()

    def _finish(self, result, done) -> None:
        if isinstance(result, Exception):
            self._say(str(result))
        elif done is not None:
            done(result)

    def _say(self, text: str) -> None:
        self.message.configure(text=text)

    # ---- the buttons ----------------------------------------------------

    def _start(self) -> None:
        self._say("starting…")
        self._off_thread(
            lambda: self.supervisor.start(), lambda _: self._say("started")
        )

    def _stop(self) -> None:
        self._say("stopping…")
        self._off_thread(lambda: self.supervisor.stop(), lambda _: self._say("stopped"))

    def _pull(self) -> None:
        """Sync once, here, rather than waiting for the server's own timer.

        In this process and not as a subprocess: the store is already open,
        WAL means the running server reading the same file is a non-event, and
        every record applies by id, so a pull that overlaps the server's own
        five-minute one costs a duplicate fetch and nothing worse.
        """
        from .sync import Backend, Puller

        self._say("pulling…")
        self.pull.state(["disabled"])

        def work():
            with Backend(self.config.server, self.config.token) as backend:
                return Puller(self.config, self.store, backend).pull()

        def done(report) -> None:
            self.metrics.pulled(report.ok)
            self.pull.state(["!disabled"])
            self._say(str(report))
            self._search()

        self._off_thread(work, done)

    def _toggle_service(self) -> None:
        wanted = self.at_login.get()
        unit = render_unit(
            host=self.supervisor.host,
            port=self.supervisor.port,
            config_file=self.config_file,
            cache_dir=self.config.cache_dir,
        )

        def work() -> str:
            try:
                install_service(unit) if wanted else uninstall_service()
            except (RuntimeError, OSError) as error:
                return f"could not change it: {error}"
            return "installed as a user service" if wanted else "service removed"

        def done(message: str) -> None:
            self._say(message)
            # From disk rather than from what was clicked: a tick next to a
            # service that was never installed is the one wrong thing this
            # checkbox can say.
            self.at_login.set(service_installed())

        self._off_thread(work, done)

    def _search(self) -> None:
        query = self.query.get()
        self._off_thread(
            lambda: self.store.search(query, limit=200), self._show_results
        )

    def _show_results(self, items: list[Item]) -> None:
        self.results.delete(*self.results.get_children())
        for item in items:
            self.results.insert(
                "", "end", values=(item.when, item.source[:28], item.title)
            )
        self._say(f"{len(items)} matching")

    # ---- the status pane -------------------------------------------------

    def _poll(self) -> None:
        supervisor = self.supervisor

        def work():
            counts = self.store.counts()
            cursor = self.store.setting("sync.cursor")
            if supervisor is None:
                return counts, cursor, True, False, None
            scraped = supervisor.scraped()
            return (
                counts,
                cursor,
                supervisor.healthy(),
                supervisor.managed,
                # The server's own numbers while it is up; ours while it is
                # not, so a pull done from this window still shows.
                scraped if scraped is not None else from_metrics(self.metrics),
            )

        self._off_thread(work, self._draw)
        self.root.after(int(POLL_SECONDS * 1000), self._poll)

    def _draw(self, seen) -> None:
        counts, cursor, running, managed, scraped = seen
        url = self.config.remote or (
            self.supervisor.url if self.supervisor else str(self.config.database)
        )
        self.status.configure(
            text=status_line(running=running, url=url, managed=managed)
        )
        for label, value in format_stats(counts, cursor, scraped):
            self.stat_values[label].configure(text=value)
        if self.local:
            self.start.state(["disabled"] if running else ["!disabled"])
            self.stop.state(["!disabled"] if running else ["disabled"])


def gui(config: Config, *, config_file: Path | str | None = None,
        host: str = "127.0.0.1", port: int = 8100) -> int:
    """The `gui` subcommand. See cli.py."""
    return run_gui(config, config_file or default_config_path(), host, port)
