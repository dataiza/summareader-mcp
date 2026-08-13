"""Opening what the server stores.

See `summareader/docs/SYNC_PROTOCOL.md` §3 and §5. Two details are worth
having in front of you, because both fail silently:

* **Compress, then encrypt.** Decrypting gives gzip, not text.
* **The MAC is separate on the wire.** libsodium returns ciphertext‖tag as one
  buffer; this format keeps them apart, joined by full stops with the nonce.
  So opening means concatenating them back before handing them to libsodium.
"""

from __future__ import annotations

import base64
import gzip
import hashlib
import hmac
from dataclasses import dataclass

from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_aead_xchacha20poly1305_ietf_encrypt,
)
from nacl.utils import random as nacl_random

NONCE_BYTES = 24
MAC_BYTES = 16


@dataclass(frozen=True)
class SealedBlob:
    nonce: bytes
    ciphertext: bytes
    mac: bytes

    @classmethod
    def from_wire(cls, wire: str) -> SealedBlob:
        """Parse `base64(nonce).base64(ciphertext).base64(mac)`.

        A malformed string is not an error. The Dart side yields an empty blob
        that decrypts to nothing and skips the entry, and a reader that threw
        here would stop syncing over one bad row.
        """
        parts = wire.split(".")
        if len(parts) != 3:
            return cls(b"", b"", b"")
        try:
            return cls(*(base64.b64decode(part, validate=True) for part in parts))
        except Exception:
            return cls(b"", b"", b"")

    def to_wire(self) -> str:
        return ".".join(
            base64.b64encode(part).decode("ascii")
            for part in (self.nonce, self.ciphertext, self.mac)
        )

    @property
    def empty(self) -> bool:
        return not self.nonce or not self.ciphertext


def open_bytes(blob: SealedBlob, key: bytes) -> bytes | None:
    """The plaintext, or None if this is not ours to read.

    None covers every failure on purpose: a truncated entry, one sealed under
    a different key, one that is not an envelope at all. The caller skips it —
    an entry written by a newer version must not stop the log.
    """
    if blob.empty:
        return None
    try:
        compressed = crypto_aead_xchacha20poly1305_ietf_decrypt(
            blob.ciphertext + blob.mac, None, blob.nonce, key
        )
        return gzip.decompress(compressed)
    except Exception:
        return None


def open_text(blob: SealedBlob, key: bytes) -> str | None:
    raw = open_bytes(blob, key)
    if raw is None:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def seal_bytes(plaintext: bytes, key: bytes) -> SealedBlob:
    """Only the tests and the vectors need this — the mirror reads.

    Kept because a reader that cannot also write has no way to prove it agrees
    with the other implementation about anything but the samples it was given.
    """
    nonce = nacl_random(NONCE_BYTES)
    sealed = crypto_aead_xchacha20poly1305_ietf_encrypt(
        gzip.compress(plaintext), None, nonce, key
    )
    return SealedBlob(nonce, sealed[:-MAC_BYTES], sealed[-MAC_BYTES:])


def seal_text(text: str, key: bytes) -> SealedBlob:
    return seal_bytes(text.encode("utf-8"), key)


def blob_name(plaintext: bytes, name_key: bytes) -> str:
    """Content-addressed, and unlinkable across accounts.

    The name is a MAC of the content hash under a per-account key, so the same
    article stored twice costs one blob while two accounts holding it cannot be
    told they both have it.
    """
    digest = hashlib.sha256(plaintext).digest()
    mac = hmac.new(name_key, digest, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(mac).decode("ascii").replace("=", "")


def image_parts(raw: bytes) -> tuple[str, bytes] | None:
    """An image blob is `<contentType>\\n<base64 bytes>` before sealing."""
    try:
        head, encoded = raw.decode("utf-8").split("\n", 1)
    except (UnicodeDecodeError, ValueError):
        return None
    try:
        return head, base64.b64decode(encoded, validate=True)
    except Exception:
        return None
