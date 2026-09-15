"""One program, several ways in.

`serve` is the default so an MCP client configured as `command:
summareader-mcp` keeps working. The rest exist because the same questions are
worth asking without a language model in the room — and because a search you
can run in a terminal is a search you can check.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime
from pathlib import Path

from . import __version__
from .config import Config, ConfigError, default_config_path
from .report import render
from .store import Store, open_store
from .store.remote import RemoteError, RemoteStore
from .tools import BadSince, parse_since


def main(argv: list[str] | None = None) -> int:
    # Text out in utf-8 whatever the console's codepage says, because half of
    # what this prints — an arrow in a status line, somebody's article title —
    # is not in cp1252, and a redirected stdout on Windows is exactly where
    # that becomes a traceback instead of a line. Anything that is not a real
    # text stream, pytest's capture among them, has no such problem.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")

    parser = _parser()
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except (ConfigError, FileNotFoundError, RemoteError) as error:
        print(f"summareader-mcp: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="summareader-mcp",
        description="Mirror a SummaReader library and ask it questions.",
    )
    parser.add_argument("--version", action="version", version=__version__)
    parser.add_argument(
        "--config",
        metavar="FILE",
        help=f"config file (default: {default_config_path()})",
    )
    parser.add_argument(
        "--remote",
        metavar="URL",
        help="read a mirror somebody else is running, over its http transport "
        "— e.g. http://box:8100. Needs no config, no keys and no library of "
        "its own; the token comes from SUMMAREADER_MCP_TOKEN. Not --server, "
        "which in the config file means the sync server this mirrors *from*",
    )
    parser.add_argument(
        "--library",
        metavar="PATH",
        help="read this SummaReader library file directly, read-only, and do "
        "not sync at all — for running on the same machine as the app",
    )
    parser.set_defaults(run=_serve)
    sub = parser.add_subparsers()

    serve = sub.add_parser("serve", help="the MCP server (the default)")
    serve.add_argument("--transport", choices=("stdio", "http"), default="stdio")
    # No defaults here: a flag that defaults is a flag that cannot be told
    # apart from an unset one, and the config file's host and port would then
    # never win over an argparse default nobody typed. The defaults live in
    # Config, which is the one place configuration is resolved.
    serve.add_argument(
        "--host",
        help="what the http transport binds (default: the config's host, or "
        "loopback; a container wants 0.0.0.0, since its port is published by "
        "the runtime)",
    )
    serve.add_argument("--port", type=int, help="default: the config's port, or 8100")
    serve.set_defaults(run=_serve)

    pull = sub.add_parser("pull", help="sync once and say what arrived")
    pull.set_defaults(run=_pull)

    search = sub.add_parser("search", help="search the library")
    search.add_argument("query", nargs="*", help="words to look for")
    _filters(search)
    search.add_argument("--format", choices=("text", "md", "csv", "json"), default="text")
    search.set_defaults(run=_search)

    recent = sub.add_parser("recent", help="the newest articles")
    recent.add_argument("--limit", type=int, default=20)
    recent.add_argument("--format", choices=("text", "md", "csv", "json"), default="text")
    recent.set_defaults(run=_recent)

    report = sub.add_parser("report", help="write a set of articles to a file")
    report.add_argument("query", nargs="*")
    _filters(report)
    report.add_argument("--format", choices=("md", "csv", "json"), default="md")
    report.add_argument("--out", metavar="FILE", help="write here instead of stdout")
    report.add_argument("--heading", default="Library report")
    report.set_defaults(run=_report)

    status = sub.add_parser("status", help="what this mirror holds and where it is")
    status.set_defaults(run=_status)

    ui = sub.add_parser("ui", help="the terminal interface")
    ui.set_defaults(run=_ui)

    return parser


def _filters(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--title", help="only titles with a word starting like this")
    parser.add_argument("--source", help="only feeds with a word starting like this")
    parser.add_argument("--since", help="published after: 3h, 7d, 3w, 2026-08-01")
    parser.add_argument("--until", help="published before: 3h, 7d, 3w, 2026-08-01")
    parser.add_argument("--read-since", help="read after: 3h, 7d, 2026-08-01")
    parser.add_argument("--read-until", help="read before: 3h, 7d, 2026-08-01")
    parser.add_argument("--unread", action="store_true", help="only unread")
    parser.add_argument("--summarized", action="store_true", help="only summarized")
    parser.add_argument(
        "--not-summarized", action="store_true", help="only those without a summary"
    )
    parser.add_argument("--limit", type=int, default=50)


# ---- the commands ------------------------------------------------------


def _search(args) -> int:
    with _store(args) as store:
        items = _query(store, args)
    if args.format == "text":
        _print_lines(items)
    else:
        print(render(items, args.format), end="")
    return 0


def _recent(args) -> int:
    with _store(args) as store:
        items = store.recent(limit=args.limit)
    if args.format == "text":
        _print_lines(items)
    else:
        print(render(items, args.format), end="")
    return 0


def _report(args) -> int:
    with _store(args) as store:
        items = _query(store, args)
    text = render(items, args.format, title=args.heading)
    if args.out:
        # utf-8 rather than whatever the console's codepage is: a title with an
        # em dash in it is not an encoding error on anybody's machine.
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"{len(items)} articles → {args.out}", file=sys.stderr)
    else:
        print(text, end="")
    return 0


def _status(args) -> int:
    config = _config(args)
    with _store(args) as store:
        counts = store.counts()
        cursor = store.setting("sync.cursor")
        instance = store.setting("sync.instanceId")
    print(f"library   {config.remote or config.database}")
    if config.remote:
        # Everything below is the mirror's own bookkeeping, and this process is
        # not the mirror. The cursor is a fact about the library, so it stays.
        print("mode      reading a mirror over its http transport")
        print(f"cursor    {cursor or 0}")
    elif config.reads_a_local_library:
        print("mode      reading the app's own library, read-only")
    else:
        print(f"server    {config.server}")
        print(f"name      {config.name or '(unset — the server shows its enrolled label)'}")
        print(f"cursor    {cursor or 0}{f' on {instance}' if instance else ''}")
    print(
        f"holds     {counts['items']} articles · {counts['unread']} unread · "
        f"{counts['summarized']} summarized · {counts['bodies']} with text · "
        f"{counts['sources']} sources"
    )
    return 0


def _pull(args) -> int:
    from .sync import pull_once

    config = _config(args)
    if config.reads_a_local_library:
        print("nothing to pull: --library reads a file that is already here.")
        return 0
    return pull_once(config)


def _serve(args) -> int:
    from .server import serve

    config = _config(args)
    _say_where(config)
    # Flag, then environment, then file, then default — the last three are
    # Config.load's order already, so this line only has to add the flag.
    return serve(
        config,
        transport=getattr(args, "transport", "stdio"),
        host=getattr(args, "host", None) or config.host,
        port=getattr(args, "port", None) or config.port,
    )


def _say_where(config) -> None:
    """Which library this is, said out loud, once.

    The window asks where the mirror should go on its first run. A server
    started over ssh has nobody to ask, so it takes the default and says which
    one it took — that is the whole of the headless half of the same question.

    And if the move out of ~/.cache left one behind, it names that too. The old
    one is not adopted and not moved: this is the most complete copy of
    somebody's library, and an unattended relocation of it is the one operation
    here with no undo.
    """
    from .config import stranded_library

    print(f"summareader-mcp: library in {config.database}", file=sys.stderr)
    if (old := stranded_library(config)) is not None:
        print(
            f"summareader-mcp: an older library is still at {old} — "
            "this one starts empty and rebuilds from the log. Copy it over "
            "instead if you would rather not re-download everything.",
            file=sys.stderr,
        )


def _ui(args) -> int:
    from .tui import run_ui

    return run_ui(_config(args), _store(args) if args.remote else None)


# ---- shared ------------------------------------------------------------


def _config(args) -> Config:
    if args.remote:
        if args.run in (_serve, _pull):
            # Both need the master key, and a reader over the port has none by
            # design. Saying so beats "master_key is 32 bytes, not 0".
            raise ConfigError(
                "--remote reads a mirror; it cannot be one. Drop --remote, or "
                "run this against the machine that holds the library."
            )
        return Config.for_remote(
            args.remote, token=os.environ.get("SUMMAREADER_MCP_TOKEN")
        )
    if args.library:
        return Config.for_library(args.library)
    return Config.load(file=args.config)


def _store(args):
    """The library, wherever it is — a file here, or a mirror over there.

    One seam, because everything downstream asks a store the same questions
    and none of it cares which kind answered.
    """
    if args.remote:
        return RemoteStore(args.remote, token=os.environ.get("SUMMAREADER_MCP_TOKEN"))
    config = _config(args)
    return open_store(config.database, read_only=config.reads_a_local_library)


def _query(store: Store, args) -> list:
    summarized = True if args.summarized else (False if args.not_summarized else None)
    return store.search(
        " ".join(args.query),
        title=args.title,
        source=args.source,
        since=_since(args.since),
        until=_since(args.until),
        read_since=_since(args.read_since),
        read_until=_since(args.read_until),
        unread=True if args.unread else None,
        summarized=summarized,
        limit=args.limit,
    )


def _print_lines(items: list) -> None:
    """One article per line, and the summary indented under it.

    Not a table: a title is as long as it is, and a terminal that wraps a
    column is worse to read than one that wraps a line.
    """
    if not items:
        print("Nothing matches.", file=sys.stderr)
        return
    for item in items:
        mark = " " if item.read else "•"
        print(f"{mark} {item.when}  {item.source[:24]:24}  {item.title}")
        if item.summary and item.summary.tldr:
            print(f"    {item.summary.tldr}")




def _since(value: str | None) -> datetime | None:
    try:
        return parse_since(value)
    except BadSince as bad:
        raise ConfigError(f"--since {bad}")


if __name__ == "__main__":  # `python -m summareader_mcp.cli`, for a checkout
    raise SystemExit(main())
