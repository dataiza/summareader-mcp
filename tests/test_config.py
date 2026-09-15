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
    stranded_library,
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


class TestTheBearerToken:
    def test_from_the_file(self, tmp_path):
        config = Config.load(file=write(tmp_path, bearer_token="s3cret"),
                             environment={})
        assert config.bearer_token == "s3cret"

    def test_the_name_it_had_before_the_rename_still_works(self, tmp_path):
        # `http_token` is on disk in config files nobody is going to edit
        # today, and it guards the port: reading only the new spelling would
        # open the library to anyone who could reach it.
        config = Config.load(file=write(tmp_path, http_token="s3cret"),
                             environment={})
        assert config.bearer_token == "s3cret"

    def test_the_new_name_wins_when_both_are_there(self, tmp_path):
        config = Config.load(
            file=write(tmp_path, bearer_token="new", http_token="old"),
            environment={},
        )
        assert config.bearer_token == "new"

    def test_the_environment_wins_over_either(self, tmp_path):
        config = Config.load(
            file=write(tmp_path, http_token="old"),
            environment={"SUMMAREADER_MCP_TOKEN": "from-the-environment"},
        )
        assert config.bearer_token == "from-the-environment"


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

    def test_the_file_can_switch_it_off(self, tmp_path):
        # JSON spells this false, not "false", and only strings were read —
        # so the one place this switch is meant to be set did nothing.
        config = Config.load(file=write(tmp_path, fetch_bodies=False), environment={})
        assert not config.fetch_bodies

    def test_and_can_be_switched_off(self, tmp_path):
        config = Config.load(
            file=write(tmp_path), environment={"SUMMAREADER_MCP_BODIES": "false"}
        )
        assert not config.fetch_bodies


class TestTheAddressItBinds:
    """The console edits these, so the file has to hold them.

    Flag, environment, file, default — the flag half lives in cli.py and is
    asserted in test_cli; the other three are here.
    """

    def test_loopback_and_8100_when_nobody_says(self, tmp_path):
        config = Config.load(file=write(tmp_path), environment={})
        assert (config.host, config.port) == ("127.0.0.1", 8100)

    def test_from_the_file(self, tmp_path):
        # A port is a number in JSON, which is how the console writes it.
        config = Config.load(
            file=write(tmp_path, host="0.0.0.0", port=9000), environment={}
        )
        assert (config.host, config.port) == ("0.0.0.0", 9000)

    def test_the_environment_wins_over_the_file(self, tmp_path):
        config = Config.load(
            file=write(tmp_path, host="0.0.0.0", port=9000),
            environment={
                "SUMMAREADER_MCP_HOST": "10.0.0.5",
                "SUMMAREADER_MCP_PORT": "9999",
            },
        )
        assert (config.host, config.port) == ("10.0.0.5", 9999)

    def test_a_port_that_is_not_a_number_says_so(self, tmp_path):
        with pytest.raises(ConfigError) as raised:
            Config.load(file=write(tmp_path, port="eight thousand"), environment={})
        assert "port is a number" in str(raised.value)


class TestHowOftenItPulls:
    def test_five_minutes_when_nobody_says(self, tmp_path):
        assert Config.load(file=write(tmp_path), environment={}).poll_seconds == 300

    def test_from_the_file_or_the_environment(self, tmp_path):
        assert (
            Config.load(file=write(tmp_path, poll_seconds=60), environment={})
            .poll_seconds
            == 60
        )
        assert (
            Config.load(
                file=write(tmp_path), environment={"SUMMAREADER_MCP_POLL": "30"}
            ).poll_seconds
            == 30
        )


class TestTheLibraryKey:
    """`--library` in the file, so the console and the mirror read one file."""

    def test_needs_no_server_no_token_and_no_key(self, tmp_path):
        path = tmp_path / "config.json"
        library = tmp_path / "app.sqlite"
        path.write_text(json.dumps({"library": str(library)}), encoding="utf-8")
        config = Config.load(file=path, environment={})
        assert config.reads_a_local_library
        assert config.database == library

    def test_from_the_environment_too(self, tmp_path):
        config = Config.load(
            file=write(tmp_path),
            environment={"SUMMAREADER_MCP_LIBRARY": str(tmp_path / "app.sqlite")},
        )
        assert config.database == tmp_path / "app.sqlite"


class TestWhatTheConsoleWrites:
    """The round trip the console's Address chooser does, checked from here.

    The writing itself is Dart — see console/test/config_test.dart — but the
    file it leaves behind has to be one this reads back unchanged, which is a
    question only this side can answer.
    """

    def test_what_the_console_leaves_behind_is_read_back(self, tmp_path):
        path = tmp_path / "config.json"
        # Comment keys, an unknown key and the old spelling of the token: what
        # the console preserves, spelled the way the example file spells it.
        path.write_text(
            json.dumps(
                {
                    "_comment": "written by hand",
                    "server": "https://sync.example",
                    "token": "t",
                    "master_key": KEY,
                    "http_token": "s3cret",
                    "something_this_version_never_heard_of": 7,
                    "host": "0.0.0.0",
                    "port": 9000,
                }
            ),
            encoding="utf-8",
        )
        config = Config.load(file=path, environment={})
        assert (config.host, config.port) == ("0.0.0.0", 9000)
        assert config.bearer_token == "s3cret"
        assert config.master_key == base64.b64decode(KEY)


class TestWhereItLooksWhenNobodySays:
    """The defaults were /config and /cache, which only a container can use.

    On Windows those land on the root of the system drive and on macOS they
    belong to root, so an unprivileged app cannot create either. What has to
    keep working is the container and the systemd unit, and both say where
    they want things in the environment.
    """

    def test_linux_puts_the_library_in_the_data_directory(self, tmp_path):
        """Not the cache directory, which is what this asserted before.

        The mirror runs no retention, so it is the most complete copy of a
        library rather than a subset of one — and ~/.cache is exactly what a
        disk cleaner empties. The config file stays where it was.
        """
        env = {
            "XDG_CONFIG_HOME": str(tmp_path / "c"),
            "XDG_DATA_HOME": str(tmp_path / "d"),
            # Still set, and still ignored for the library: proving the move
            # rather than the absence of the old variable.
            "XDG_CACHE_HOME": str(tmp_path / "k"),
        }
        assert default_config_path(platform="linux", environment=env) == (
            tmp_path / "c/summareader-mcp/summareader-mcp.json"
        )
        assert default_cache_dir(platform="linux", environment=env) == (
            tmp_path / "d/summareader-mcp"
        )

    def test_a_relative_xdg_data_home_is_ignored(self):
        """The specification says absolute.

        Resolving a relative one against the working directory is how a server
        started from two different shells ends up with two libraries and no way
        to tell which is which.
        """
        got = default_cache_dir(
            platform="linux", environment={"XDG_DATA_HOME": "relative/share"}
        )
        assert got == Path.home() / ".local/share/summareader-mcp"

    def test_macos_uses_the_user_library(self):
        path = default_config_path(platform="darwin", environment={})
        assert "Library/Application Support/summareader-mcp" in str(path)
        assert str(path).startswith(str(Path.home()))

    def test_macos_keeps_both_in_one_directory(self):
        """What this platform offers, taken rather than fought.

        There is no separate data location on macOS worth the name, so the
        config file and library.sqlite sit side by side — which is what the
        sync server's console already calls "one directory is the whole
        installation".
        """
        data = default_cache_dir(platform="darwin", environment={})
        config = default_config_path(platform="darwin", environment={})
        assert data == config.parent
        assert "Library/Caches" not in str(data)

    def test_windows_uses_appdata(self, tmp_path):
        env = {"APPDATA": str(tmp_path / "Roaming"), "LOCALAPPDATA": str(tmp_path / "Local")}
        assert default_config_path(platform="win32", environment=env) == (
            tmp_path / "Roaming/summareader-mcp/summareader-mcp.json"
        )
        # The trailing "cache" component is gone with the name: it is the data
        # directory now, and LOCALAPPDATA is where that belongs.
        assert default_cache_dir(platform="win32", environment=env) == (
            tmp_path / "Local/summareader-mcp"
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


class TestTheLibraryLeftBehind:
    """The move out of the cache directory does not take the library with it.

    Nothing is moved and nothing is deleted: this is the only complete copy of
    somebody's reading, and relocating it unattended is the one operation in
    that change with no undo. It is named instead, once, on stderr.
    """

    def test_an_old_library_is_named_when_the_new_place_is_empty(self, tmp_path):
        old = tmp_path / "cache/summareader-mcp"
        old.mkdir(parents=True)
        (old / "library.sqlite").write_bytes(b"")

        config = Config.load(
            file=write(tmp_path),
            environment={"SUMMAREADER_MCP_CACHE": str(tmp_path / "data")},
        )
        found = stranded_library(config, {"XDG_CACHE_HOME": str(tmp_path / "cache")})
        assert found == old / "library.sqlite"

    def test_nothing_is_said_once_the_new_one_exists(self, tmp_path):
        """Otherwise it would say it on every start, for ever."""
        old = tmp_path / "cache/summareader-mcp"
        old.mkdir(parents=True)
        (old / "library.sqlite").write_bytes(b"")
        new = tmp_path / "data"
        new.mkdir()
        (new / "library.sqlite").write_bytes(b"")

        config = Config.load(
            file=write(tmp_path),
            environment={"SUMMAREADER_MCP_CACHE": str(new)},
        )
        assert stranded_library(config, {"XDG_CACHE_HOME": str(tmp_path / "cache")}) is None

    def test_no_old_library_is_not_a_finding(self, tmp_path):
        config = Config.load(
            file=write(tmp_path),
            environment={"SUMMAREADER_MCP_CACHE": str(tmp_path / "data")},
        )
        assert stranded_library(config, {"XDG_CACHE_HOME": str(tmp_path / "nowhere")}) is None
