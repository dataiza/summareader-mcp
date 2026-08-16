"""The ways small models mangle JSON, and what to do about each.

Ported from `summareader/packages/summareader_core/test/summary_format_test.dart`,
whose cases are a corpus of real failures from a real library rather than
imagined ones. A client that skips this shows a reader a wall of braces where
the summary should be, for a meaningful share of their items.
"""

from __future__ import annotations

import json

import pytest

from summareader_mcp.summary import (
    SummaryParseError,
    parse_summary,
    parse_summary_or_prose,
)


class TestTheOrdinaryCase:
    def test_clean_json_is_simply_read(self):
        summary = parse_summary(
            '{"tldr":"One sentence.","points":[{"text":"A point"}],'
            '"long":"Several paragraphs."}'
        )
        assert summary.tldr == "One sentence."
        assert [p.text for p in summary.points] == ["A point"]
        assert summary.long == "Several paragraphs."

    def test_nothing_at_all_is_an_error_rather_than_an_empty_summary(self):
        with pytest.raises(SummaryParseError):
            parse_summary("")


class TestTheRepairs:
    def test_fenced_output(self):
        assert parse_summary('```json\n{"tldr":"Fenced."}\n```').tldr == "Fenced."

    def test_an_opening_fence_with_no_closing_one(self):
        # The response was cut off before it finished.
        assert parse_summary('```json\n{"tldr":"Cut off."}').tldr == "Cut off."

    def test_prose_either_side_of_the_object(self):
        assert (
            parse_summary(
                'Certainly! Here is your summary:\n{"tldr":"Wrapped."}\nHope that helps!'
            ).tldr
            == "Wrapped."
        )

    def test_double_encoding(self):
        # The whole object arrives as a JSON *string*.
        assert parse_summary(json.dumps('{"tldr":"Encoded twice."}')).tldr == (
            "Encoded twice."
        )

    def test_a_trailing_comma(self):
        assert parse_summary('{"tldr":"Trailing.",}').tldr == "Trailing."

    def test_an_element_opened_and_abandoned(self):
        assert (
            parse_summary('{"tldr":"Abandoned.","points":[{"text":"a"},{').tldr
            == "Abandoned."
        )

    def test_truncation_mid_object(self):
        summary = parse_summary('{"tldr":"Truncated mid-sentence and never clos')
        assert summary.tldr.startswith("Truncated mid-sentence")

    def test_a_brace_inside_the_summary_does_not_confuse_the_isolation(self):
        # The naive first-to-last slice breaks here, and a summary *about*
        # JSON contains braces.
        summary = parse_summary(
            'Here you go: {"tldr":"The author writes {\\"a\\": 1} to show it."}'
        )
        assert '{"a": 1}' in summary.tldr


class TestWhatIsNotASummary:
    def test_the_prompt_template_handed_back(self):
        # Valid JSON, populated field, and completely useless — stored as fine,
        # the reader shows somebody "<overview>".
        with pytest.raises(SummaryParseError):
            parse_summary('{"tldr":"<overview>"}')

    def test_every_field_empty(self):
        with pytest.raises(SummaryParseError):
            parse_summary('{"tldr":"","points":[],"long":""}')

    def test_json_that_is_not_a_summary_at_all(self):
        with pytest.raises(SummaryParseError):
            parse_summary('{"tags":[]}')


class TestTheAnswerInsideTheAnswer:
    def test_a_whole_reply_stuffed_into_the_first_field(self):
        # The outer object is valid, so no repair above ever runs.
        summary = parse_summary(
            json.dumps({"tldr": '```json\n{"tldr":"The real one.","long":"Notes."}\n```'})
        )
        assert summary.tldr == "The real one."
        assert summary.long == "Notes."

    def test_a_whole_document_hiding_in_full_notes(self):
        summary = parse_summary(
            json.dumps(
                {
                    "tldr": "A perfectly ordinary sentence.",
                    "long": '{"tldr":"short","long":"The actual notes."}',
                }
            )
        )
        assert summary.long == "The actual notes."
        assert "{" not in (summary.long or "")

    def test_notes_that_merely_contain_a_brace_are_left_alone(self):
        summary = parse_summary(
            json.dumps(
                {
                    "tldr": "On JSON, at some length.",
                    "long": 'The author writes {"a": 1} to show the shape.',
                }
            )
        )
        assert '{"a": 1}' in summary.long


class TestProse:
    def test_a_model_that_answered_in_prose_is_taken_at_its_word(self):
        written = (
            "The X6 is a better camera than the X5 in three ways. "
            "The stabilisation is the one that matters on a motorcycle."
        )
        summary = parse_summary_or_prose(written)
        assert summary.long == written
        assert summary.tldr.startswith("The X6 is a better camera")

    def test_a_failed_json_attempt_gives_up_its_fields_not_its_braces(self):
        broken = (
            '{"tldr": "A long enough one-line version to keep here.", '
            '"long": "The notes, in prose.", "points": [{"text": "a"'
        )
        summary = parse_summary_or_prose(broken)
        assert summary.tldr == "A long enough one-line version to keep here."
        assert summary.long == "The notes, in prose."

    def test_and_never_keeps_the_document_as_the_notes(self):
        broken = '{"tldr": "A long enough one-line version to keep here.", "points": [{'
        summary = parse_summary_or_prose(broken)
        assert summary.long is None
        assert "{" not in summary.tldr

    def test_broken_json_with_nothing_readable_is_a_failure(self):
        with pytest.raises(SummaryParseError):
            parse_summary_or_prose('{"tldr": "too short", "poi')


class TestPoints:
    def test_a_timestamp_anchor_becomes_a_time_that_seeks(self):
        summary = parse_summary(
            '{"tldr":"A video.","points":[{"text":"[01:30] What happens"}]}'
        )
        assert summary.points[0].at_ms == 90_000
        assert summary.points[0].text == "What happens"

    def test_an_hour_long_anchor_is_read(self):
        summary = parse_summary(
            '{"tldr":"A long one.","points":[{"text":"[01:02:03] Late on"}]}'
        )
        assert summary.points[0].at_ms == 3_723_000

    def test_a_point_with_no_anchor_keeps_its_text_and_no_time(self):
        summary = parse_summary('{"tldr":"An article.","points":[{"text":"A point"}]}')
        assert summary.points[0].at_ms is None
        assert summary.points[0].text == "A point"

    def test_bare_strings_are_points_too(self):
        summary = parse_summary('{"tldr":"A thing.","points":["[00:05] First"]}')
        assert summary.points[0].at_ms == 5_000

    def test_an_empty_entry_yields_nothing(self):
        summary = parse_summary('{"tldr":"A thing.","points":["", {}, 7]}')
        assert summary.points == []


def test_glossary_terms_carry_their_definitions() -> None:
    raw = (
        '{"tldr":"An overview long enough to count as one.",'
        '"glossary":[{"term":"HKDF","definition":"key derivation"},"XChaCha20"]}'
    )

    summary = parse_summary(raw)

    assert [g.term for g in summary.glossary] == ["HKDF", "XChaCha20"]
    assert summary.glossary[0].definition == "key derivation"
    # A bare string is a term with nothing to say about itself, which is every
    # glossary written before definitions existed.
    assert summary.glossary[1].definition is None


def test_subject_slugs_survive_the_rename() -> None:
    # Written before the rename: `points` for the entries, `topics` for the
    # slugs. The Dart side had this fallback and this one did not, so a summary
    # of that shape lost its slugs here.
    before = '{"tldr":"An overview long enough.","points":["A."],"topics":["linux"]}'
    after = '{"tldr":"An overview long enough.","points":["A."],"tags":["linux"]}'

    assert parse_summary(before).tags == ["linux"]
    assert parse_summary(after).tags == ["linux"]
