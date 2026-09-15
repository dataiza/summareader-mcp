import 'package:flutter_test/flutter_test.dart';
import 'package:summareader_mcp_console/src/query.dart';

/// The same box as the terminal interface's.
///
/// Asserted against `parse_query` in `summareader_mcp/tools.py` field for
/// field: two spellings of one search is a thing to learn twice, and the
/// window taking words only meant a query that works in the terminal found
/// nothing here and said nothing about why.
void main() {
  test('words with no field are just words', () {
    final (words, filters) = parseQuery('borrow checker');

    expect(words, 'borrow checker');
    expect(filters.isEmpty, isTrue);
  });

  test('a quoted source keeps its spaces, and leaves the words alone', () {
    final (words, filters) = parseQuery('rust source:"The Morning Paper"');

    expect(words, 'rust');
    expect(filters.source, 'The Morning Paper');
  });

  test('aliases are the ones the terminal takes', () {
    final (_, filters) = parseQuery('feed:lwn after:7d before:2026-08-01');

    expect(filters.source, 'lwn');
    expect(filters.since, isNotNull);
    expect(filters.until, DateTime.utc(2026, 8, 1));
  });

  test('flags read yes and no', () {
    expect(parseQuery('unread:yes').$2.unread, isTrue);
    expect(parseQuery('unread:no').$2.unread, isFalse);
    expect(parseQuery('summarized:0').$2.summarized, isFalse);
  });

  test('tags repeat and narrow', () {
    expect(parseQuery('tag:linux tag:kernel').$2.tags, ['linux', 'kernel']);
  });

  test('relative dates count backwards from now', () {
    final now = DateTime.now().toUtc();
    final since = parseQuery('since:7d').$2.since!;

    expect(now.difference(since).inHours, closeTo(168, 1));
    expect(
      now.difference(parseQuery('since:3h').$2.since!).inMinutes,
      closeTo(180, 1),
    );
  });

  test('a colon in a title costs a search, not an error', () {
    // Anything that is not a field it knows stays part of the words.
    final (words, filters) = parseQuery('rust: a memoir');

    expect(words, 'rust: a memoir');
    expect(filters.isEmpty, isTrue);
  });

  test('a date it cannot read says what to type instead', () {
    expect(
      () => parseQuery('since:whenever'),
      throwsA(
        isA<BadSince>().having((e) => e.message, 'message', contains('3h, 7d')),
      ),
    );
  });

  test('what goes to a mirror over the port has the tool\'s own names', () {
    final (_, filters) = parseQuery('source:lwn since:7d unread:yes tag:linux');
    final sent = filters.toToolArguments();

    expect(sent['source'], 'lwn');
    expect(sent['unread'], isTrue);
    expect(sent['tags'], ['linux']);
    expect(sent['since'], isA<String>());
    expect(sent.containsKey('title'), isFalse, reason: 'unset stays unsent');
  });
}
