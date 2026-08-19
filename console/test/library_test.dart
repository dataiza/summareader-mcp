/// The search box, against a real library.
///
/// Search is the mirror's entire point, and a console that answers a slightly
/// different question than `summareader-mcp search` does is worse than one
/// that answers none: nobody would notice. So the SQL here is the SQL there,
/// and the last test in this file asks the command line itself and compares
/// the rows.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:summareader_mcp_console/src/library.dart';

import 'seed.dart';

void main() {
  late Directory temporary;
  late LocalLibrary library;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('console-library');
    seedLibrary('${temporary.path}/library.sqlite');
    library = LocalLibrary.open('${temporary.path}/library.sqlite');
  });

  tearDown(() {
    library.close();
    temporary.deleteSync(recursive: true);
  });

  Future<List<String>> ids(String query) async => [
    for (final item in await library.search(query)) item.id,
  ];

  test('the counts are what the library holds', () async {
    expect(await library.counts(), {
      'items': 12,
      'unread': 7,
      'summarized': 10,
      'bodies': 1,
      'sources': 4,
    });
    expect(await library.setting('sync.cursor'), '418');
    expect(await library.setting('nothing.here'), isNull);
  });

  test('everything, newest first', () async {
    final all = await library.search('');
    expect(all.length, 12);
    expect(all.first.id, 'a1');
    expect(all.first.when, '2026-08-11');
    expect(all.first.source, 'Lime');
    expect(all.last.id, 'a12');
  });

  test('a needle is matched where a word starts', () async {
    // `rust` finds "Rust" and "rustc" and leaves "trust" alone. It is still a
    // plain substring after that first character: the whole query, spaces and
    // all, has to appear in one column in the order it was typed.
    expect(await ids('borrow'), ['a1']);
    expect(await ids('orrow'), isEmpty);
    // Out of the article text, which only a1 has — this is the half of the
    // search that no title would answer.
    expect(await ids('aliasing'), ['a1']);
    // Out of a summary.
    expect(await ids('percentiles'), ['a7']);
    // Out of the source name.
    expect(await ids('Boatbuilding'), ['a4', 'a11']);
    // Case-folded, like the command line's.
    expect(await ids('SQLITE'), ['a2']);
  });

  test('a query nothing answers is empty rather than everything', () async {
    expect(await ids('nothing in this library'), isEmpty);
  });

  test('the same rows as `search` on the command line', () async {
    // The one test that can catch the whole class of drift: two
    // implementations of one match, one of them in another language. It asks
    // the real command line, so it needs the repository's virtualenv and
    // skips where there is not one — a build machine with no Python is not a
    // reason to fail.
    final python = File('${repositoryRoot.path}/.venv/bin/python');
    if (!python.existsSync()) {
      markTestSkipped('no .venv in the repository to ask');
      return;
    }

    for (final query in [
      '',
      'rust',
      'sqlite',
      'reading',
      'the',
      'log',
      'Ink & Paper',
      'p99',
      '%',
      'nothing at all',
    ]) {
      final done = await Process.run(python.path, [
        '-m',
        'summareader_mcp',
        '--library',
        '${temporary.path}/library.sqlite',
        'search',
        '--format',
        'json',
        '--limit',
        '200',
        query,
      ], workingDirectory: repositoryRoot.path);
      expect(done.exitCode, 0, reason: '${done.stderr}');
      final rows = jsonDecode(done.stdout as String) as List;
      expect(await ids(query), [
        for (final row in rows) row['id'],
      ], reason: 'searching for "$query"');
    }
  });
}
