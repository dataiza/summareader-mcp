"""Where this mirror reads from, and what it calls itself.

JSON file first, environment second, so a container can override one field
without a new file. The pre-rename `ALLREADER_*` spellings are still accepted:
somebody's deployment predates the name.
"""

from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CONFIG = "/config/summareader-mcp.json"
DEFAULT_CACHE = "/cache"


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    server: str
    token: str
    master_key: bytes
    cache_dir: Path
    name: str | None = None
    http_token: str | None = None
    fetch_bodies: bool = True
    library: Path | None = None

    @property
    def database(self) -> Path:
        return self.library or (self.cache_dir / "library.sqlite")

    @classmethod
    def for_library(cls, path: Path | str) -> Config:
        """A mirror of nothing: read a library file that is already here.

        No server, no keys, no second copy. This is the whole configuration
        when the MCP server runs on the same machine as the app.
        """
        return cls(
            server="",
            token="",
            master_key=b"",
            cache_dir=Path(path).parent,
            library=Path(path),
        )

    @property
    def reads_a_local_library(self) -> bool:
        return self.library is not None

    @classmethod
    def load(
        cls,
        *,
        file: Path | str | None = None,
        environment: dict[str, str] | None = None,
    ) -> Config:
        env = dict(os.environ if environment is None else environment)

        def pick(key: str, env_key: str, default: str | None = None) -> str | None:
            for spelling in (env_key, env_key.replace("SUMMAREADER", "ALLREADER")):
                if env.get(spelling):
                    return env[spelling]
            value = stored.get(key)
            return value if isinstance(value, str) and value else default

        path = Path(
            file
            or env.get("SUMMAREADER_MCP_CONFIG")
            or env.get("ALLREADER_MCP_CONFIG")
            or DEFAULT_CONFIG
        )
        stored: dict = {}
        if path.exists():
            try:
                stored = json.loads(path.read_text())
            except json.JSONDecodeError as error:
                raise ConfigError(f"{path} is not valid JSON: {error}") from error

        server = pick("server", "SUMMAREADER_SYNC_URL")
        token = pick("token", "SUMMAREADER_DEVICE_TOKEN")
        master = pick("master_key", "SUMMAREADER_MASTER_KEY")
        missing = [
            name
            for name, value in (
                ("server", server),
                ("token", token),
                ("master_key", master),
            )
            if not value
        ]
        if missing:
            raise ConfigError(
                f"{', '.join(missing)} missing — set them in {path} or in the "
                "environment. See summareader-mcp.example.json."
            )

        return cls(
            server=server.rstrip("/"),
            token=token,
            master_key=_master_key(master),
            cache_dir=Path(
                env.get("SUMMAREADER_MCP_CACHE")
                or env.get("ALLREADER_MCP_CACHE")
                or DEFAULT_CACHE
            ),
            name=pick("name", "SUMMAREADER_MCP_NAME"),
            http_token=pick("http_token", "SUMMAREADER_MCP_TOKEN"),
            fetch_bodies=(pick("fetch_bodies", "SUMMAREADER_MCP_BODIES", "true") or "")
            .lower()
            not in ("false", "0", "no"),
        )


def _master_key(encoded: str) -> bytes:
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise ConfigError("master_key is not valid base64") from error
    if len(raw) != 32:
        raise ConfigError(f"master_key is 32 bytes, not {len(raw)}")
    return raw
