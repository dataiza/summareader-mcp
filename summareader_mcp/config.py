"""Where this mirror reads from, and what it calls itself.

JSON file first, environment second, so a container can override one field
without a new file. The pre-rename `ALLREADER_*` spellings are still accepted:
somebody's deployment predates the name.
"""

from __future__ import annotations

import base64
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

NAME = "summareader-mcp"


def _home(platform: str, env: dict[str, str]) -> tuple[Path, Path]:
    """Where this platform lets an unprivileged program keep things.

    The old answer was /config and /cache, which is right in the container and
    nowhere else: on Windows those resolve onto the system drive's root, and on
    macOS they belong to root and cannot be created by the app that needs them.
    The container keeps its old paths by passing the environment variables
    below — see the Dockerfile.

    The second of the pair is the **data** directory, and used to be the cache
    one. It is still spelled `cache_dir` everywhere, including in the config
    file and in SUMMAREADER_MCP_CACHE, and that mismatch is deliberate:
    renaming it would touch two Dockerfiles, two compose files, the systemd
    unit, run.sh, freeze.sh and every install that already exists, to change a
    spelling.

    The move is not cosmetic. This repository's own CHANGELOG says the mirror
    "runs no retention, so it is the most complete copy of a library rather
    than a subset of one — the cache directory deserves the care the library
    does". ~/.cache is precisely what a disk cleaner empties, and rebuilding
    costs every blob downloaded again.

    `platformdirs` would answer this in one line and is installed — but only as
    a transitive dependency of `textual`, which is the terminal interface. A
    headless server importing a GUI library's transitive dependency to find a
    path is a dependency nobody declared, so the branch stays written out.
    """
    if platform == "win32":
        base = Path(env.get("APPDATA") or Path.home() / "AppData/Roaming")
        data = Path(env.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
        return base / NAME, data / NAME
    if platform == "darwin":
        # One directory for both, which is what this platform offers and what
        # the sync server's console already calls "one directory is the whole
        # installation". The config file and library.sqlite sit side by side.
        base = Path.home() / "Library/Application Support" / NAME
        return base, base
    return (
        Path(env.get("XDG_CONFIG_HOME") or Path.home() / ".config") / NAME,
        Path(_xdg_data_home(env)) / NAME,
    )


def _xdg_data_home(env: dict[str, str]) -> Path:
    """XDG_DATA_HOME when it is absolute, else the ~/.local/share it defines.

    Relative is ignored rather than resolved. The specification requires an
    absolute path, and resolving a relative one against the working directory
    is how a server started from two different shells ends up with two
    libraries and no way to tell which is which.
    """
    named = env.get("XDG_DATA_HOME") or ""
    if named.startswith("/"):
        return Path(named)
    return Path.home() / ".local/share"


def default_config_path(
    *, platform: str | None = None, environment: dict[str, str] | None = None
) -> Path:
    env = dict(os.environ if environment is None else environment)
    return _home(platform or sys.platform, env)[0] / f"{NAME}.json"


def default_cache_dir(
    *, platform: str | None = None, environment: dict[str, str] | None = None
) -> Path:
    env = dict(os.environ if environment is None else environment)
    return _home(platform or sys.platform, env)[1]


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    server: str
    token: str
    master_key: bytes
    cache_dir: Path
    name: str | None = None
    #: The credential a caller must present to the http transport, as
    #: `Authorization: Bearer …`. Spelled `http_token` in config files written
    #: before the rename, and still read under that name.
    bearer_token: str | None = None
    fetch_bodies: bool = True
    #: What `serve --transport=http` binds when no flag says otherwise. Here
    #: rather than in the flags alone because the console changes it, and a
    #: choice made in a window has to outlive the window.
    host: str = "127.0.0.1"
    port: int = 8100
    #: Whether to pull at all. Off means a mirror that holds what it already
    #: has and asks for nothing — useful while a sync server is down, or on a
    #: machine that should read the library and never add to it. `pull` on the
    #: command line still works; this is the loop, not the verb.
    sync: bool = True
    #: Seconds between pulls. A library nobody is watching can afford to ask
    #: less often, and a shared one may want to ask more.
    poll_seconds: int = 300
    library: Path | None = None
    #: A mirror's address, when this process reads one over the port instead of
    #: holding a library of its own. See `for_remote`.
    remote: str | None = None

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

    @classmethod
    def for_remote(cls, url: str, *, token: str | None = None) -> Config:
        """A reader with no library of its own: it all comes over the port.

        No sync server, no device token and no master key, because nothing here
        decrypts anything — the mirror on the other end did that, and holding
        the plaintext is the whole of what it is for. `bearer_token` is the only
        credential a reader needs, and it is the same one the server checks.
        """
        return cls(
            server="",
            token="",
            master_key=b"",
            cache_dir=Path(),
            bearer_token=token,
            remote=url,
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
            # A JSON file spells a port as a number and a switch as a boolean,
            # and reading only strings quietly ignored both — `"fetch_bodies":
            # false` did nothing until this line.
            if isinstance(value, bool):
                return "true" if value else "false"
            if isinstance(value, (int, float)):
                return str(value)
            return value if isinstance(value, str) and value else default

        path = Path(
            file
            or env.get("SUMMAREADER_MCP_CONFIG")
            or env.get("ALLREADER_MCP_CONFIG")
            or default_config_path(environment=env)
        )
        stored: dict = {}
        if path.exists():
            try:
                stored = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as error:
                raise ConfigError(f"{path} is not valid JSON: {error}") from error

        library = pick("library", "SUMMAREADER_MCP_LIBRARY")
        if library:
            # The same configuration `for_library` builds: a file that is
            # already here needs no server, no token and no key, and demanding
            # them would make the file's spelling of --library refuse to load.
            return cls(
                server="",
                token="",
                master_key=b"",
                cache_dir=Path(library).parent,
                library=Path(library),
                host=pick("host", "SUMMAREADER_MCP_HOST", "127.0.0.1"),
                port=_number("port", pick("port", "SUMMAREADER_MCP_PORT", "8100")),
            )

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
                pick("cache_dir", "SUMMAREADER_MCP_CACHE")
                or default_cache_dir(environment=env)
            ),
            name=pick("name", "SUMMAREADER_MCP_NAME"),
            # `http_token` was the old spelling, and config files holding it
            # are on disk on machines nobody is going to edit today. Read
            # rather than migrated: rewriting somebody's config to rename a key
            # is a bigger liberty than reading two names.
            bearer_token=(
                pick("bearer_token", "SUMMAREADER_MCP_TOKEN")
                or pick("http_token", "SUMMAREADER_MCP_TOKEN")
            ),
            fetch_bodies=(pick("fetch_bodies", "SUMMAREADER_MCP_BODIES", "true") or "")
            .lower()
            not in ("false", "0", "no"),
            host=pick("host", "SUMMAREADER_MCP_HOST", "127.0.0.1"),
            port=_number("port", pick("port", "SUMMAREADER_MCP_PORT", "8100")),
            sync=(pick("sync", "SUMMAREADER_MCP_SYNC", "true") or "").lower()
            not in ("false", "0", "no"),
            poll_seconds=_number(
                "poll_seconds", pick("poll_seconds", "SUMMAREADER_MCP_POLL", "300")
            ),
        )


def _number(name: str, value) -> int:
    """A port that is not a number is a server that will not start.

    Said here, where the file is read, rather than as a ValueError out of
    whatever eventually tried to bind it.
    """
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ConfigError(f"{name} is a number, not {value!r}") from None


def _master_key(encoded: str) -> bytes:
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise ConfigError("master_key is not valid base64") from error
    if len(raw) != 32:
        raise ConfigError(f"master_key is 32 bytes, not {len(raw)}")
    return raw


def stranded_library(config: "Config", environment: dict[str, str] | None = None) -> Path | None:
    """The library left behind by the move out of the cache directory.

    Returns the old path when it holds a library and the new one does not, so
    the caller can say where it is. Nothing is moved and nothing is deleted
    here: this is the only complete copy of somebody's reading, and relocating
    it unattended is the one operation in this change with no undo.

    Rebuilding is what happens if it is ignored — the mirror is reconstructible
    from the log — and that costs every blob downloaded again, which is a thing
    to be told about rather than to discover from a progress bar.
    """
    env = dict(os.environ if environment is None else environment)
    if config.database.exists():
        return None
    old = Path(env.get("XDG_CACHE_HOME") or Path.home() / ".cache") / NAME
    stranded = old / "library.sqlite"
    return stranded if stranded.exists() and old != config.cache_dir else None

