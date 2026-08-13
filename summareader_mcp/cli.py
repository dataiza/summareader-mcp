"""One program, several ways in.

`serve` is the default so an MCP client configured as `command:
summareader-mcp` keeps working. The rest exist because the same questions are
worth asking without a language model in the room — and because a search you
can run in a terminal is a search you can check.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import __version__
from .config import Config, ConfigError
from .report import render
from .store import Store, open_store


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except ConfigError as error:
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
        "--config", metavar="FILE", help="config file (default: /config/summareader-mcp.json)"
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
    serve.add_argument("--port", type=int, default=8100)
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
    report.add_argument("--title", default="Library report")
    report.set_defaults(run=_report)

    status = sub.add_parser("status", help="what this mirror holds and where it is")
    status.set_defaults(run=_status)

    ui = sub.add_parser("ui", help="the terminal interface")
    ui.set_defaults(run=_ui)

    return parser


def _filters(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source", help="only this feed (substring)")
    parser.add_argument("--since", help="only newer than this: 7d, 3w, 2026-08-01")
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
    text = render(items, args.format, title=args.title)
    if args.out:
        Path(args.out).write_text(text)
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
    print(f"library   {config.database}")
    if config.reads_a_local_library:
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

    return serve(
        _config(args),
        transport=getattr(args, "transport", "stdio"),
        port=getattr(args, "port", 8100),
    )


def _ui(args) -> int:
    from .tui import run_ui

    return run_ui(_config(args))


# ---- shared ------------------------------------------------------------


def _config(args) -> Config:
    if args.library:
        return Config.for_library(args.library)
    return Config.load(file=args.config)


def _store(args) -> Store:
    config = _config(args)
    return open_store(config.database, read_only=config.reads_a_local_library)


def _query(store: Store, args) -> list:
    summarized = True if args.summarized else (False if args.not_summarized else None)
    return store.search(
        " ".join(args.query),
        source=args.source,
        since=_since(args.since),
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


_RELATIVE = re.compile(r"^(\d+)([dwmy])$")


def _since(value: str | None) -> datetime | None:
    """`7d`, `3w`, or a date. Anything else is an error rather than a guess."""
    if not value:
        return None
    match = _RELATIVE.match(value.strip().lower())
    if match:
        count, unit = int(match.group(1)), match.group(2)
        days = {"d": 1, "w": 7, "m": 30, "y": 365}[unit] * count
        return datetime.now(timezone.utc) - timedelta(days=days)
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise ConfigError(f"--since {value}: expected 7d, 3w, or a date like 2026-08-01")
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


if __name__ == "__main__":  # `python -m summareader_mcp.cli`, for a checkout
    raise SystemExit(main())
