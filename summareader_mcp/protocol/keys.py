"""Subkeys, derived from the one master key.

See `summareader/docs/SYNC_PROTOCOL.md` §2. The purpose strings are spelled
`allreader` because the app was called that once, and renaming them would make
every existing log unreadable. They are frozen, not stale.
"""

from __future__ import annotations

from dataclasses import dataclass

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


class KeyPurpose:
    """The info strings. Frozen — see the module docstring."""

    LOG_ENTRIES = "allreader/v1/log"
    BLOB_CONTENTS = "allreader/v1/blob"
    BLOB_NAMES = "allreader/v1/name"
    DEVICE_WRAP = "allreader/v1/device"
    RECOVERY_WRAP = "allreader/v1/recovery"


def subkey(master: bytes, purpose: str) -> bytes:
    """One 32-byte subkey.

    HKDF-SHA256 with **no salt** — not a zero-filled one, an absent one. The
    master is already full-entropy random, so a salt would buy nothing and
    would have to be agreed between devices.
    """
    if len(master) != 32:
        raise ValueError(f"the master key is 32 bytes, not {len(master)}")
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,
        info=purpose.encode("utf-8"),
    ).derive(master)


@dataclass(frozen=True)
class SyncKeys:
    """The three a reader needs, derived once and held together."""

    log_entries: bytes
    blob_contents: bytes
    blob_names: bytes

    @classmethod
    def derive(cls, master: bytes) -> SyncKeys:
        return cls(
            log_entries=subkey(master, KeyPurpose.LOG_ENTRIES),
            blob_contents=subkey(master, KeyPurpose.BLOB_CONTENTS),
            blob_names=subkey(master, KeyPurpose.BLOB_NAMES),
        )
