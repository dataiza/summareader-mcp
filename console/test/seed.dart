/// The demo library both pictures are taken of.
///
/// The same articles, feeds and dates `scripts/screenshot.py` describes, so
/// the console's picture and the terminal interface's are of one library
/// rather than of two inventions. Written through the mirror's own schema —
/// read out of the Python package next door rather than transcribed, because
/// a second copy of a schema is a second schema.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// The repository this console lives in. `flutter test` runs from `console/`.
Directory get repositoryRoot => Directory.current.parent;

const _feeds = {
  'lime': 'Lime',
  'themorningpaper': 'The Morning Paper',
  'boatbuildingweekly': 'Boatbuilding Weekly',
  'inkpaper': 'Ink & Paper',
};

const _items = [
  (
    'a1',
    'What the borrow checker actually proves',
    'lime',
    '2026-08-11T08:20:00.000Z',
    false,
  ),
  (
    'a2',
    'SQLite as an application file format',
    'lime',
    '2026-08-09T17:05:00.000Z',
    true,
  ),
  (
    'a3',
    'Why your backups are not backups until you restore one',
    'themorningpaper',
    '2026-08-08T06:00:00.000Z',
    false,
  ),
  (
    'a4',
    'Rebuilding a wooden dinghy over one winter',
    'boatbuildingweekly',
    '2026-08-05T12:40:00.000Z',
    true,
  ),
  (
    'a5',
    'The case against ambient notifications',
    'inkpaper',
    '2026-08-03T09:15:00.000Z',
    false,
  ),
  (
    'a6',
    'Reading RSS in 2026, deliberately',
    'inkpaper',
    '2026-07-31T20:00:00.000Z',
    true,
  ),
  (
    'a7',
    'Measuring latency without lying to yourself',
    'themorningpaper',
    '2026-07-28T11:30:00.000Z',
    false,
  ),
  (
    'a8',
    'A field guide to sourdough failure',
    'inkpaper',
    '2026-07-26T07:45:00.000Z',
    true,
  ),
  (
    'a9',
    'Static binaries and the machines that outlive them',
    'lime',
    '2026-07-24T15:10:00.000Z',
    false,
  ),
  (
    'a10',
    'Keeping a paper notebook alongside the terminal',
    'inkpaper',
    '2026-07-21T18:00:00.000Z',
    false,
  ),
  (
    'a11',
    'The winter storage checklist nobody follows',
    'boatbuildingweekly',
    '2026-07-19T09:25:00.000Z',
    true,
  ),
  (
    'a12',
    'Reading the log forward, once',
    'themorningpaper',
    '2026-07-17T13:05:00.000Z',
    false,
  ),
];

const _summaries = {
  'a1': (
    'Ownership is a proof about aliasing, not about memory: the allocator is '
        'a consequence of the rule, never its point.',
    [
      'A borrow is a claim that nobody else is writing right now.',
      'Lifetimes annotate the claim; they do not create it.',
      '`unsafe` suspends the proof, not the rules it was proving.',
    ],
  ),
  'a2': (
    'A single file with transactions beats a directory of formats nobody '
        'agreed on, and survives the crash halfway through a save.',
    [
      'Atomic writes come free; a hand-rolled format has to earn them.',
      'One file is one thing to copy, back up and hand over.',
    ],
  ),
  'a3': (
    'An untested backup is a belief. The restore is the only part anybody '
        'ever actually needs.',
    [
      'Schedule the restore, not only the dump.',
      'Measure how long a restore takes before the day it matters.',
    ],
  ),
  'a4': (
    'Epoxy hides a bad joint for about two seasons; the survey finds it in '
        'the third.',
    [
      'Strip the paint before deciding what the hull is worth.',
      'Fastenings first, cosmetics last.',
    ],
  ),
  'a6': (
    'A feed reader is the last piece of software that does not decide for '
        'you what you meant to read.',
    [
      'Chronological is a feature, not a limitation.',
      'Subscriptions are portable; timelines are not.',
    ],
  ),
  'a7': (
    'Averages describe a distribution nobody is experiencing. Report '
        'percentiles or report nothing.',
    [
      'Coordinated omission hides the worst requests you have.',
      'A p99 over an hour is not a p99 over a minute.',
    ],
  ),
  'a8': (
    'Almost every flat loaf is one of four things, and three of them are '
        'temperature.',
    [
      'A cold kitchen is a slow starter, not a dead one.',
      'Shape it tight; slack dough spreads instead of rising.',
    ],
  ),
  'a9': (
    'Linking everything in is how a program still runs on a box nobody has '
        'patched since it was installed.',
    [
      'The dependency you did not ship cannot be missing.',
      'Size on disk is the cheapest thing being traded away.',
    ],
  ),
  'a11': (
    'Water left anywhere freezes somewhere expensive; the list is mostly '
        'about draining things.',
    [
      'Drain the engine before the first hard night, not after.',
      'Cover it so air still moves, or the mould does the work.',
    ],
  ),
  'a12': (
    'An append-only log is only simple while every reader agrees where it '
        'left off.',
    [
      'A cursor is state; treat it like one.',
      'Re-reading from zero must stay cheap enough to be an option.',
    ],
  ),
};

const body =
    'Ownership in Rust is usually taught as a memory-management story: the '
    'compiler frees things for you, so you do not have to. That is true, and '
    'it is the least interesting half of it.\n\n'
    'The rule the compiler actually enforces is about aliasing. At any moment '
    'a value may have many readers or exactly one writer, never both. '
    'Deallocation is safe because of that rule, not the other way around — '
    'which is why the same checker catches an iterator invalidated mid-loop, '
    'a data race across two threads, and a file handle used after it was '
    'handed away, none of which are allocation bugs at all.\n';

/// Write the demo library at [path], schema and all.
void seedLibrary(String path) {
  final schema = File('${repositoryRoot.path}/summareader_mcp/store/schema.sql')
      .readAsStringSync();
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL');
  db.execute(schema);

  for (final entry in _feeds.entries) {
    db.execute('INSERT INTO channels (id, kind, url, title) VALUES (?,?,?,?)', [
      entry.key,
      'rss',
      'https://${entry.key}.example/feed',
      entry.value,
    ]);
  }

  for (final (id, title, feed, published, read) in _items) {
    final at = DateTime.parse(published).millisecondsSinceEpoch ~/ 1000;
    db.execute(
      'INSERT INTO items (id, canonical_url, title, published_at, fetched_at, '
      'read) VALUES (?,?,?,?,?,?)',
      [id, 'https://example.com/$id', title, at, at, read ? 1 : 0],
    );
    db.execute(
      'INSERT INTO item_channels (item_id, channel_id, first_seen_at) '
      'VALUES (?,?,?)',
      [id, feed, at],
    );
    final summary = _summaries[id];
    if (summary != null) {
      db.execute(
        'INSERT INTO summaries (item_id, model_id, created_at, text, state) '
        "VALUES (?,?,?,?,'ok')",
        [
          id,
          'qwen2.5:14b',
          at + 1200,
          jsonEncode({'tldr': summary.$1, 'points': summary.$2}),
        ],
      );
    }
  }

  db.execute(
    'INSERT INTO extracted_texts (item_id, text, word_count) '
    'VALUES (?,?,?)',
    ['a1', body, body.split(RegExp(r'\s+')).length],
  );
  db.execute("INSERT INTO settings (key, value) VALUES ('sync.cursor', '418')");
  db.dispose();
}
