"""Where the mirror reads from, and what it calls itself."""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from summareader_mcp.config import Config, ConfigError

KEY = base64.b64encode(bytes(range(32))).decode()


def write(tmp_path: Path, **fields) -> Path:
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"server": "https://sync.example", "token": "t",
                                "master_key": KEY, **fields}))
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
        path.write_text(json.dumps({"server": "https://s.example"}))
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
