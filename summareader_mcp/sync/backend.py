"""The sync server, over HTTP.

See `summareader/docs/SYNC_PROTOCOL.md` §1. Only the read half is here plus
`rename`: this is a mirror, and the one thing it says about itself is what to
call it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx


class SyncFailure(Exception):
    """Anything the server refused or could not do."""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status

    @property
    def unauthorized(self) -> bool:
        return self.status in (401, 403)


@dataclass(frozen=True)
class Entry:
    seq: int
    payload: str
    device: str | None = None


class Backend:
    def __init__(self, base_url: str, token: str, *, timeout: float = 30.0) -> None:
        self._client = httpx.Client(
            base_url=base_url.rstrip("/"),
            headers={"authorization": f"Bearer {token}"},
            timeout=timeout,
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> Backend:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def instance(self) -> str:
        """Which server this is.

        A cursor without one is a number that means nothing: `seq` is
        transport-local, so the same entries carry different numbers elsewhere.
        """
        return str(self._get("/instance").get("instance") or "")

    def read_from(self, seq: int, *, limit: int = 500) -> list[Entry]:
        body = self._get(f"/from/{seq}", params={"limit": limit})
        entries = body.get("entries")
        if not isinstance(entries, list):
            raise SyncFailure("the server did not return a list of entries")
        return [
            Entry(seq=e["seq"], payload=e["payload"], device=e.get("device"))
            for e in entries
            if isinstance(e, dict)
            and isinstance(e.get("seq"), int)
            and isinstance(e.get("payload"), str)
        ]

    def blob(self, name: str) -> str | None:
        """The sealed contents, or None if the server has never seen it.

        A missing blob is ordinary: retention on the device that wrote it may
        have reclaimed the bytes while the pointer stayed in the log.
        """
        try:
            return str(self._get(f"/blob/{name}").get("payload") or "") or None
        except SyncFailure as failure:
            if failure.status == 404:
                return None
            raise

    def rename(self, label: str) -> None:
        """Set this device's own label, which is what the app's list shows.

        The mirror cannot enrol itself — a paired device mints its token — but
        it can say what it is called, because it authenticates as itself.
        """
        self._post("/rename", {"label": label})

    def _get(self, path: str, **kwargs: Any) -> dict:
        return self._decode(self._request("GET", path, **kwargs))

    def _post(self, path: str, body: dict) -> dict:
        return self._decode(self._request("POST", path, json=body))

    def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            response = self._client.request(method, path, **kwargs)
        except httpx.HTTPError as error:
            raise SyncFailure(f"{path}: {error}") from error
        if response.status_code >= 400:
            raise SyncFailure(
                f"{path}: {response.status_code} {response.text[:200]}",
                status=response.status_code,
            )
        return response

    @staticmethod
    def _decode(response: httpx.Response) -> dict:
        try:
            # Explicitly UTF-8: the server sends bare `application/json`.
            body = response.json()
        except ValueError as error:
            raise SyncFailure(f"the server did not send JSON: {error}") from error
        return body if isinstance(body, dict) else {}
