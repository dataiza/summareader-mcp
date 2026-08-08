import 'package:summareader_core/summareader_core.dart';
import 'package:summareader_mcp/src/library_mirror.dart';
import 'package:summareader_mcp/src/metrics.dart';
import 'package:test/test.dart';

/// What the mirror can say about itself.
///
/// The operational question here is only ever "is the mirror keeping up", so
/// these are cache numbers: how far through the log, how much that produced,
/// how long since it last read. Nothing names an article — this is the one
/// process that holds the library in plaintext, and a label carrying a title
/// would put it somewhere nobody expects to find one.
void main() {
  late SyncKeys keys;

  setUpAll(() async {
    keys = await SyncKeys.derive(MasterKey.generate());
  });

  LibraryMirror mirrorWith(List<MirroredItem> items, {int cursor = 0}) =>
      LibraryMirror(backend: _NoBackend(), keys: keys)
        ..restore(cursor: cursor, items: items);

  test('it counts the mirror, not the library', () {
    final mirror = mirrorWith([
      MirroredItem(id: 'a', seq: 1, title: 'One', summary: 'A summary.'),
      MirroredItem(id: 'b', seq: 2, title: 'Two'),
    ], cursor: 2);

    final text = mcpMetrics(mirror);

    expect(text, contains('summareader_mcp_items 2'));
    expect(text, contains('summareader_mcp_items_summarized 1'));
    expect(text, contains('summareader_mcp_cursor 2'));
  });

  test('and says how long since it last read the log', () {
    // "Up to date" and "stopped reading" look identical from the item count
    // alone, which is why the pull is counted whether or not it brought
    // anything.
    final text = mcpMetrics(mirrorWith(const []));

    expect(text, contains('summareader_mcp_last_pull_age_seconds'));
    expect(text, contains('summareader_mcp_pulls_total'));
    expect(text, contains('summareader_mcp_pull_failures_total'));
  });

  test('no title, no source, no url — ever', () {
    final mirror = mirrorWith([
      MirroredItem(
        id: 'a',
        seq: 1,
        title: 'A title nobody should see in Grafana',
        source: 'A source',
        url: 'https://example.com/secret',
        summary: 'A summary.',
      ),
    ]);

    final text = mcpMetrics(mirror);

    expect(text, isNot(contains('nobody should see')));
    expect(text, isNot(contains('example.com')));
    expect(text, isNot(contains('A source')));
  });

  test('every metric declares itself', () {
    final text = mcpMetrics(mirrorWith(const []));
    final names = {
      for (final line in text.split('\n'))
        if (line.isNotEmpty && !line.startsWith('#'))
          line.split(' ').first,
    };

    for (final name in names) {
      expect(text, contains('# HELP $name '), reason: '$name has no HELP');
      expect(text, contains('# TYPE $name '), reason: '$name has no TYPE');
    }
  });
}

class _NoBackend implements SyncBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the metrics never reach the backend');
}
