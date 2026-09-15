"""The version, in the three places that have to agree about it.

A release is named by one of them and published from a section of the
changelog. Discovering a mismatch on a tag means discovering it after the tag
is pushed, so it is checked here, on the commit that made it.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

from summareader_mcp import __version__

ROOT = Path(__file__).resolve().parent.parent


def test_pyproject_agrees() -> None:
    with (ROOT / "pyproject.toml").open("rb") as handle:
        pyproject = tomllib.load(handle)
    assert pyproject["project"]["version"] == __version__


def test_the_console_agrees() -> None:
    """The window ships beside the mirror, so one version covers both."""
    pubspec = (ROOT / "console" / "pubspec.yaml").read_text()
    found = re.search(r"^version:\s*(\S+)", pubspec, re.MULTILINE)
    assert found is not None, "console/pubspec.yaml has no version"
    assert found.group(1) == __version__


def test_the_changelog_names_this_version() -> None:
    changelog = (ROOT / "CHANGELOG.md").read_text()
    heading = f"## {__version__}"
    assert any(line.strip() == heading for line in changelog.splitlines()), (
        f"CHANGELOG.md has no {heading!r} section — write it in the same "
        f"commit as the version bump"
    )
