"""What Prometheus scrapes.

The names are unchanged from the Dart mirror on purpose: the Grafana dashboard
in `summareader/docs/grafana/summareader.json` graphs them, and a rename would
mean editing forty panels to say the same thing.
"""

from __future__ import annotations

import time

from .store import Store

_started = time.time()


class Metrics:
    def __init__(self) -> None:
        self.pulls = 0
        self.failures = 0
        self.last_pull: float | None = None

    def pulled(self, ok: bool) -> None:
        self.pulls += 1
        if not ok:
            self.failures += 1
        self.last_pull = time.time()

    def render(self, store: Store, *, name: str | None = None) -> str:
        counts = store.counts()
        newest = store.recent(limit=1)
        labels = f'{{instance="{name}"}}' if name else ""

        lines = [
            "# HELP summareader_mcp_items Articles held by the mirror.",
            "# TYPE summareader_mcp_items gauge",
            f"summareader_mcp_items{labels} {counts['items']}",
            "# HELP summareader_mcp_items_summarized Articles with a summary.",
            "# TYPE summareader_mcp_items_summarized gauge",
            f"summareader_mcp_items_summarized{labels} {counts['summarized']}",
            "# HELP summareader_mcp_cursor Where the mirror has read up to.",
            "# TYPE summareader_mcp_cursor gauge",
            f"summareader_mcp_cursor{labels} {int(store.setting('sync.cursor') or 0)}",
            "# HELP summareader_mcp_pulls_total Sync passes attempted.",
            "# TYPE summareader_mcp_pulls_total counter",
            f"summareader_mcp_pulls_total{labels} {self.pulls}",
            "# HELP summareader_mcp_pull_failures_total Sync passes that failed.",
            "# TYPE summareader_mcp_pull_failures_total counter",
            f"summareader_mcp_pull_failures_total{labels} {self.failures}",
        ]

        # Ages rather than timestamps: "how long since" is the question, and a
        # gauge that answers it needs no clock skew argument on the dashboard.
        if self.last_pull is not None:
            lines += [
                "# HELP summareader_mcp_last_pull_age_seconds Since the last pull.",
                "# TYPE summareader_mcp_last_pull_age_seconds gauge",
                f"summareader_mcp_last_pull_age_seconds{labels} "
                f"{time.time() - self.last_pull:.0f}",
            ]
        if newest and newest[0].published:
            age = time.time() - newest[0].published.timestamp()
            lines += [
                "# HELP summareader_mcp_newest_item_age_seconds Age of the newest article.",
                "# TYPE summareader_mcp_newest_item_age_seconds gauge",
                f"summareader_mcp_newest_item_age_seconds{labels} {age:.0f}",
            ]

        lines += [
            "# HELP summareader_mcp_uptime_seconds How long this process has run.",
            "# TYPE summareader_mcp_uptime_seconds gauge",
            f"summareader_mcp_uptime_seconds{labels} {time.time() - _started:.0f}",
        ]
        return "\n".join(lines) + "\n"
