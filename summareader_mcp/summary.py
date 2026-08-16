"""Turning what a model returned into something a person can read.

A `summary` record's `text` is the model's own JSON, as it came back. Small
models mangle it, and the Dart side spends 782 lines on the ways they do —
`summareader/packages/summareader_core/lib/src/summary_format.dart`, whose
tests are a corpus of real failures rather than imagined ones.

This is the same ladder, in the same order, and the order is the point: each
repair runs **only after the strict parse has failed**, so a clean response is
never put through something that could corrupt it.

What a client that skips this shows a reader is a wall of braces where the
summary should be, for a meaningful share of their library.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

# Keys that carry actual content. At least one must be present, so a stray
# `{"tags": []}` in a model's preamble cannot hijack the parse.
_CONTENT_KEYS = frozenset(
    {"summary", "tldr", "topics", "points", "long", "analysis", "glossary"}
)

_PLACEHOLDER = re.compile(r"^<[^>]{0,80}>$")
_ECHOES = (
    "<overview>",
    "<key point>",
    "<1-3 sentences",
    "<one key point per entry>",
    "<connected prose, or omit>",
)


class SummaryParseError(Exception):
    """The model produced nothing usable."""


@dataclass(frozen=True)
class SummaryPoint:
    text: str
    at_ms: int | None = None
    title: str | None = None


@dataclass(frozen=True)
class GlossaryEntry:
    """A term and what it means here.

    The definition is optional because every glossary written before terms had
    definitions is a list of bare strings, and those are still read — as terms
    with nothing after them rather than as nothing at all.
    """

    term: str
    definition: str | None = None


@dataclass(frozen=True)
class Summary:
    tldr: str
    points: list[SummaryPoint] = field(default_factory=list)
    long: str | None = None
    #: Subject slugs. Named after the key the prompt asks for; it used to be
    #: ``topics``, which is now what a reader calls the explained ``points``.
    tags: list[str] = field(default_factory=list)
    glossary: list[GlossaryEntry] = field(default_factory=list)
    language: str | None = None

    @property
    def empty(self) -> bool:
        return not self.tldr and not self.points and not (self.long or "")


def parse_summary(response: str) -> Summary:
    """The ladder. Raises rather than inventing a summary from nothing."""
    text = (response or "").strip()
    if not text:
        raise SummaryParseError("the model returned nothing")

    # 1 — strict. The common case, and the only path that touches well-formed
    #     output.
    strict = _try_object(text)
    if strict is not None:
        return _from_map(strict)

    # 2 — strip code fences.
    unfenced = _strip_fences(text)
    if unfenced != text:
        decoded = _try_object(unfenced)
        if decoded is not None:
            return _from_map(decoded)

    # 3 — isolate the outermost {…}, discarding prose either side of it.
    isolated = _isolate_object(unfenced)
    if isolated is not None:
        decoded = _try_object(isolated)
        if decoded is not None:
            return _from_map(decoded)

        # 4 — drop an element the model opened and abandoned, then the comma it
        #     left behind. Both in one real response, in that order.
        untrailed = _drop_trailing_commas(_drop_dangling_element(isolated))
        if untrailed != isolated:
            decoded = _try_object(untrailed)
            if decoded is not None:
                return _from_map(decoded)

        # 5 — escape stray quotes left unescaped inside a string.
        quoted = _escape_stray_quotes(untrailed)
        if quoted != untrailed:
            decoded = _try_object(quoted)
            if decoded is not None:
                return _from_map(decoded)

        # 6 — repair truncation. Only once every honest parse has failed.
        for candidate in (isolated, untrailed, quoted):
            repaired = _close_truncated(candidate)
            if repaired is None:
                continue
            decoded = _try_object(repaired)
            if decoded is not None:
                return _from_map(decoded)

    raise SummaryParseError("no JSON object in the response")


def parse_summary_or_prose(text: str) -> Summary:
    """Parse it, or take the model at its word.

    A small model asked for JSON sometimes answers in prose instead. That
    answer is not wrong — it is a summary in the wrong shape — and throwing it
    away leaves the reader an error where a summary should be.
    """
    try:
        return parse_summary(text)
    except SummaryParseError:
        prose = (text or "").strip()
        if not prose:
            raise

        # A failed JSON attempt is not prose, and its first 300 characters are
        # not a summary. Read the fields out by name instead.
        if _looks_like_json(prose):
            salvaged = _salvage(prose)
            if salvaged is not None:
                return salvaged
            raise

        opening = re.match(r"^(.{20,400}?[.!?])(\s|$)", prose, re.S)
        return Summary(
            tldr=opening.group(1).strip() if opening else prose[:300],
            long=prose,
        )


def _from_map(raw: dict[str, Any]) -> Summary:
    lower = {str(k).lower(): v for k, v in raw.items()}

    # 0 — the answer inside the answer. Some models put their whole reply,
    #     fences and all, inside the first field. The outer object is valid, so
    #     nothing above catches it and the reader sees raw JSON where the
    #     one-line version belongs.
    nested = _nested_summary(lower.get("tldr") or lower.get("summary"))
    if nested is not None:
        return _from_map(nested)

    # 0b — a fragment as the one-liner, the whole answer beside it. What is
    #      already stored from before the repairs existed.
    if _looks_like_json(_string(lower.get("tldr")) or ""):
        whole = _string(lower.get("long") or lower.get("analysis"))
        if whole and _looks_like_json(whole):
            try:
                return parse_summary(whole)
            except SummaryParseError:
                salvaged = _salvage(whole)
                if salvaged is not None:
                    return Summary(
                        tldr=salvaged.tldr,
                        points=_points(lower.get("points") or lower.get("topics")),
                        long=salvaged.long,
                        glossary=_glossary(lower.get("glossary")),
                    )

    summary = Summary(
        tldr=_string(lower.get("tldr") or lower.get("summary")) or "",
        points=_points(lower.get("points") or lower.get("topics")),
        long=_long_from(_string(lower.get("long") or lower.get("analysis"))),
        tags=_strings(lower.get("tags"))
        or (_strings(lower.get("topics")) if lower.get("points") else []),
        glossary=_glossary(lower.get("glossary")),
        language=_string(lower.get("language")),
    )

    if summary.empty:
        raise SummaryParseError("parsed, but every content field was empty")
    if _is_placeholder(summary.tldr):
        # The model handed the template back instead of filling it in. The JSON
        # is valid and the field is populated, so nothing else catches it — and
        # stored as fine, the reader shows somebody "<overview>".
        raise SummaryParseError("the model echoed the prompt template")
    return summary


def _long_from(value: str | None) -> str | None:
    """Full notes, with a whole summary document taken back out of it.

    The outer object can be perfectly good JSON while `long` holds the entire
    reply as a string. The strict parse succeeds, so no repair runs, and the
    reader opens Full Notes onto a wall of braces.
    """
    if value is None or not _looks_like_json(value):
        return value
    nested = _nested_summary(value)
    if nested is not None:
        lower = {str(k).lower(): v for k, v in nested.items()}
        return _long_from(_string(lower.get("long") or lower.get("analysis")))
    return _field_from(value, r"long|analysis")


def _salvage(document: str) -> Summary | None:
    """What can be read out of a document that will not parse.

    Never keeps the raw document: `long` is prose somebody reads, and a failed
    machine answer is not prose.
    """
    one = _field_from(document, r"tl;?dr|summary")
    if one is None or len(one) <= 20:
        return None
    return Summary(tldr=one, long=_field_from(document, r"long|analysis"))


def _field_from(text: str, name_pattern: str) -> str | None:
    match = re.search(
        rf'"(?:{name_pattern})"\s*:\s*"((?:[^"\\]|\\.)*)"', text, re.IGNORECASE
    )
    if match is None:
        return None
    value = _unescape(match.group(1)).strip()
    return value or None


def _unescape(raw: str) -> str:
    return (
        raw.replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace('\\"', '"')
        .replace("\\\\", "\\")
    )


def _looks_like_json(text: str) -> bool:
    stripped = text.lstrip()
    return stripped.startswith("```") or stripped.startswith("{")


def _is_placeholder(value: str) -> bool:
    trimmed = value.strip()
    if not trimmed:
        return False
    if _PLACEHOLDER.match(trimmed):
        return True
    return trimmed.lower().startswith(_ECHOES)


def _has_content(raw: dict[str, Any]) -> bool:
    return any(str(k).lower() in _CONTENT_KEYS for k in raw)


def _try_object(text: str) -> dict[str, Any] | None:
    try:
        decoded = json.loads(text)
    except Exception:
        return None
    if isinstance(decoded, dict) and _has_content(decoded):
        return decoded
    # Double encoding: the whole object arrives as a JSON *string*.
    if isinstance(decoded, str):
        try:
            inner = json.loads(decoded)
        except Exception:
            return None
        if isinstance(inner, dict) and _has_content(inner):
            return inner
    return None


def _nested_summary(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    # Cheap rejection first: this runs on every summary that parses cleanly.
    if not text.startswith("```") and not text.startswith("{"):
        return None
    unfenced = _strip_fences(text)
    decoded = _try_object(unfenced)
    if decoded is None:
        isolated = _isolate_object(unfenced)
        decoded = _try_object(isolated) if isolated else None
    if decoded is None:
        return None
    # It has to look like a summary, not merely like JSON: a model quoting a
    # JSON example in its one-line version is answering the question.
    return decoded if _has_content(decoded) else None


def _strip_fences(text: str) -> str:
    fenced = re.search(r"```(?:json|JSON)?\s*\n?(.*?)```", text, re.S)
    if fenced:
        return fenced.group(1).strip()
    # An opening fence with no closing one — the response was cut off.
    return re.sub(r"^```(?:json|JSON)?\s*\n?", "", text).strip()


def _isolate_object(text: str) -> str | None:
    """The outermost brace pair, ignoring braces inside strings.

    A naive first-to-last slice breaks the moment the summary itself contains
    a brace, which a summary about JSON does.
    """
    start = text.find("{")
    if start == -1:
        return None
    depth, in_string, escaped = 0, False, False
    for i in range(start, len(text)):
        char = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start:]


def _drop_dangling_element(text: str) -> str:
    """An array element the model opened and never closed."""
    return re.sub(r",\s*\{[^{}]*$", "", text)


def _drop_trailing_commas(text: str) -> str:
    return re.sub(r",(\s*[}\]])", r"\1", text)


def _escape_stray_quotes(text: str) -> str:
    """A quote inside a string value that the model did not escape.

    Conservative on purpose: only between a `: "` and the `"` that closes it
    on the same line, so it cannot rewrite structure.
    """

    def fix(match: re.Match[str]) -> str:
        body = match.group(2).replace('\\"', '"').replace('"', '\\"')
        return f"{match.group(1)}{body}{match.group(3)}"

    return re.sub(r'(:\s*")(.*?)("\s*[,}\]])', fix, text)


def _close_truncated(text: str) -> str | None:
    """Shut whatever the model left open, if the tail looks cut off."""
    if not text or text.rstrip().endswith("}"):
        return None
    trimmed = _drop_trailing_commas(_drop_dangling_element(text.rstrip().rstrip(",")))

    depth, in_string, escaped, stack = 0, False, False, []
    for char in trimmed:
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "{[":
            stack.append(char)
        elif char in "}]" and stack:
            stack.pop()

    if not stack and not in_string:
        return None
    closing = '"' if in_string else ""
    closing += "".join("}" if opened == "{" else "]" for opened in reversed(stack))
    return _drop_trailing_commas(trimmed + closing)


def _string(value: Any) -> str | None:
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    return None


def _glossary(value: Any) -> list[GlossaryEntry]:
    """A glossary in either shape it can arrive in.

    A bare string is every glossary stored before terms had definitions, and is
    also what a small model returns when it ignores the object shape. Both are
    terms; one of them simply has nothing to say about itself.
    """
    if not isinstance(value, list):
        return []
    entries: list[GlossaryEntry] = []
    for entry in value:
        if isinstance(entry, str):
            term = entry.strip()
            if term:
                entries.append(GlossaryEntry(term=term))
        elif isinstance(entry, dict):
            term = _string(entry.get("term") or entry.get("name") or entry.get("word"))
            if not term:
                continue
            entries.append(
                GlossaryEntry(
                    term=term,
                    definition=_string(
                        entry.get("definition")
                        or entry.get("meaning")
                        or entry.get("description")
                    ),
                )
            )
    return entries


def _strings(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [s.strip() for s in value if isinstance(s, str) and s.strip()]


_ANCHOR = re.compile(r"^\s*\[?(\d{1,2}):(\d{2})(?::(\d{2}))?\]?\s*")


def _points(value: Any) -> list[SummaryPoint]:
    if not isinstance(value, list):
        return []
    points: list[SummaryPoint] = []
    for entry in value:
        if isinstance(entry, str):
            point = _point_from_string(entry)
        elif isinstance(entry, dict):
            text = _string(entry.get("text")) or _string(entry.get("point"))
            if text is None:
                continue
            at_ms = entry.get("atMs")
            point = SummaryPoint(
                text=text,
                at_ms=at_ms if isinstance(at_ms, int) else None,
                title=_string(entry.get("title")),
            )
            if point.at_ms is None:
                point = _point_from_string(text)
        else:
            continue
        if point is not None:
            points.append(point)
    return points


def _point_from_string(raw: str) -> SummaryPoint | None:
    text = raw.strip()
    if not text:
        return None
    match = _ANCHOR.match(text)
    if match is None:
        return SummaryPoint(text=text)
    first, second, third = match.group(1), match.group(2), match.group(3)
    if third is None:
        at_ms = (int(first) * 60 + int(second)) * 1000
    else:
        at_ms = (int(first) * 3600 + int(second) * 60 + int(third)) * 1000
    return SummaryPoint(text=text[match.end() :].strip() or text, at_ms=at_ms)
