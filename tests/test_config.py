"""Where the mirror reads from, and what it calls itself."""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from summareader_mcp.config import (
    Config,
    ConfigError,
    default_cache_dir,
    default_config_path,
)

KEY = base64.b64encode(bytes(range(32))).decode()


def write(tmp_path: Path, **fields) -> Path:
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps({"server": "https://sync.example", "token": "t",
                    "master_key": KEY, **fields}),
        encoding="utf-8",
    )
    return path


class TestLoading:
    def test_a_complete_file(self, tmp_path):
        config = Config.load(file=write(tmp_path), environment={})
        assert config.server == "https://sync.example"
        assert len(config.master_key) == 32

    def test_the_environment_wins_over_the_file(self, tmp_path):
        config = Config.load(
            file=write(tmp_path),
            environment={"SUMMAREADER_SYNC_URL": "https://other.example"},
        )
        assert config.server == "https://other.example"

    def test_the_name_it_had_before_the_rename_still_works(self, tmp_path):
        # Somebody's deployment predates the name and should not break on it.
        config = Config.load(
            file=write(tmp_path), environment={"ALLREADER_SYNC_URL": "https://old.example"}
        )
        assert config.server == "https://old.example"

    def test_a_trailing_slash_is_not_part_of_the_address(self, tmp_path):
        config = Config.load(
            file=write(tmp_path, server="https://sync.example/"), environment={}
        )
        assert config.server == "https://sync.example"

    def test_what_is_missing_is_named(self, tmp_path):
        path = tmp_path / "config.json"
        path.write_text(json.dumps({"server": "https://s.example"}), encoding="utf-8")
        with pytest.raises(ConfigError) as raised:
            Config.load(file=path, environment={})
        assert "token" in str(raised.value) and "master_key" in str(raised.value)

    def test_a_key_of_the_wrong_length_is_refused_before_anything_uses_it(self, tmp_path):
        with pytest.raises(ConfigError) as raised:
            Config.load(
                file=write(tmp_path, master_key=base64.b64encode(b"short").decode()),
                environment={},
            )
        assert "32 bytes" in str(raised.value)

    def test_a_key_that_is_not_base64_says_so(self, tmp_path):
        with pytest.raises(ConfigError) as raised:
            Config.load(file=write(tmp_path, master_key="not base64!"), environment={})
        assert "base64" in str(raised.value)


class TestTheName:
    def test_unset_by_default(self, tmp_path):
        assert Config.load(file=write(tmp_path), environment={}).name is None

    def test_from_the_file(self, tmp_path):
        config = Config.load(file=write(tmp_path, name="MCP mirror"), environment={})
        assert config.name == "MCP mirror"

    def test_from_the_environment(self, tmp_path):
        config = Config.load(
            file=write(tmp_path), environment={"SUMMAREADER_MCP_NAME": "Reports box"}
        )
        assert config.name == "Reports box"


class TestReadingALibraryDirectly:
    def test_needs_no_server_no_token_and_no_key(self, tmp_path):
        # The whole configuration when this runs on the same machine as the app.
        config = Config.for_library(tmp_path / "library.sqlite")
        assert config.reads_a_local_library
        assert config.database == tmp_path / "library.sqlite"
        assert config.server == "" and config.token == ""


class TestBodies:
    def test_on_by_default(self, tmp_path):
        assert Config.load(file=write(tmp_path), environment={}).fetch_bodies

    def test_and_can_be_switched_off(self, tmp_path):
        config = Config.load(
            file=write(tmp_path), environment={"SUMMAREADER_MCP_BODIES": "false"}
        )
        assert not config.fetch_bodies


class TestWhereItLooksWhenNobodySays:
    """The defaults were /config and /cache, which only a container can use.

    On Windows those land on the root of the system drive and on macOS they
    belong to root, so an unprivileged app cannot create either. What has to
    keep working is the container and the systemd unit, and both say where
    they want things in the environment.
    """

    def test_linux_follows_xdg(self, tmp_path):
        env = {"XDG_CONFIG_HOME": str(tmp_path / "c"), "XDG_CACHE_HOME": str(tmp_path / "k")}
        assert default_config_path(platform="linux", environment=env) == (
            tmp_path / "c/summareader-mcp/summareader-mcp.json"
        )
        assert default_cache_dir(platform="linux", environment=env) == (
            tmp_path / "k/summareader-mcp"
        )

    def test_macos_uses_the_user_library(self):
        path = default_config_path(platform="darwin", environment={})
        assert "Library/Application Support/summareader-mcp" in str(path)
        assert str(path).startswith(str(Path.home()))

    def test_windows_uses_appdata(self, tmp_path):
        env = {"APPDATA": str(tmp_path / "Roaming"), "LOCALAPPDATA": str(tmp_path / "Local")}
        assert default_config_path(platform="win32", environment=env) == (
            tmp_path / "Roaming/summareader-mcp/summareader-mcp.json"
        )
        assert default_cache_dir(platform="win32", environment=env) == (
            tmp_path / "Local/summareader-mcp/cache"
        )

    def test_nothing_defaulted_is_an_absolute_posix_path(self):
        for platform in ("linux", "darwin", "win32"):
            for path in (
                default_config_path(platform=platform, environment={}),
                default_cache_dir(platform=platform, environment={}),
            ):
                assert not str(path).startswith("/config")
                assert not str(path).startswith("/cache")

    def test_the_container_still_gets_the_paths_it_mounts(self, tmp_path):
        # What the Dockerfile sets and the systemd unit passes. This is the
        # whole compatibility story: the environment wins, as it always did.
        config = write(tmp_path)
        loaded = Config.load(
            file=config,
            environment={"SUMMAREADER_MCP_CACHE": "/cache"},
        )
        assert loaded.cache_dir == Path("/cache")
        assert loaded.database == Path("/cache/library.sqlite")

    def test_the_config_file_is_found_by_environment_too(self, tmp_path):
        config = write(tmp_path)
        loaded = Config.load(
            file=None, environment={"SUMMAREADER_MCP_CONFIG": str(config)}
        )
        assert loaded.server == "https://sync.example"
