"""What Prometheus scrapes, and the dashboard that graphs it.

The names are inherited from the Dart mirror on purpose: renaming one would
mean editing forty panels in `summareader/docs/grafana/summareader.json` to say
the same thing. This test reads that dashboard and checks nothing has gone
missing — the kind of break that shows up as an empty panel weeks later rather
than as a failure now.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

import pytest

from summareader_mcp.metrics import Metrics
from summareader_mcp.protocol.records import LogOp, LogRecord
from summareader_mcp.store import open_store

DASHBOARD = Path(
    os.environ.get(
        "SUMMAREADER_DASHBOARD",
        Path(__file__).resolve().parents[2]
        / "summareader" / "docs" / "grafana" / "summareader.json",
    )
)


@pytest.fixture
def rendered(tmp_path):
    store = open_store(tmp_path / "l.sqlite")
    store.apply_all(
        [
            LogRecord(
                op=LogOp.ITEM,
                id="a",
                data={
                    "url": "https://example.com/a",
                    "title": "A title",
                    "published": "2026-08-01T10:00:00.000Z",
                    "fetched": "2026-08-01T10:00:00.000Z",
                    "channels": [{"id": "c", "kind": "rss", "url": "https://f.example"}],
                    "read": False,
                },
            )
        ]
    )
    store.set_setting("sync.cursor", "42")
    metrics = Metrics()
    metrics.pulled(ok=True)
    metrics.pulled(ok=False)
    text = metrics.render(store, name="mirror")
    store.close()
    return text


def test_every_metric_the_dashboard_graphs_is_emitted(rendered):
    if not DASHBOARD.exists():
        pytest.skip(f"no dashboard at {DASHBOARD}")
    wanted = set(re.findall(r"summareader_mcp_[a-z_]+", DASHBOARD.read_text()))
    emitted = set(re.findall(r"^(summareader_mcp_[a-z_]+)\{", rendered, re.M))
    assert not wanted - emitted, f"the dashboard graphs these and nothing emits them: {wanted - emitted}"


def test_the_numbers_are_the_ones_asked_for(rendered):
    assert 'summareader_mcp_items{instance="mirror"} 1' in rendered
    assert 'summareader_mcp_cursor{instance="mirror"} 42' in rendered
    assert 'summareader_mcp_pulls_total{instance="mirror"} 2' in rendered
    assert 'summareader_mcp_pull_failures_total{instance="mirror"} 1' in rendered


def test_the_name_becomes_a_label(rendered):
    # The dashboard told mirrors apart by Prometheus job name alone, which
    # needs a scrape config per mirror rather than a setting.
    assert 'instance="mirror"' in rendered


def test_no_label_when_the_mirror_has_no_name(tmp_path):
    store = open_store(tmp_path / "l.sqlite")
    text = Metrics().render(store)
    store.close()
    assert "summareader_mcp_items " in text, "bare, not with empty braces"


def test_it_is_parseable_prometheus(rendered):
    for line in rendered.splitlines():
        if line.startswith("#"):
            assert re.match(r"^# (HELP|TYPE) summareader_mcp_[a-z_]+ ", line), line
        else:
            assert re.match(r"^summareader_mcp_[a-z_]+(\{[^}]*\})? -?[\d.]+$", line), line
