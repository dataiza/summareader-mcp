import 'dart:convert';
import 'dart:io';

import 'package:allreader_core/allreader_core.dart';
import 'package:allreader_mcp/src/library_mirror.dart';
import 'package:allreader_mcp/src/mirror_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late MirrorStore store;
  late SyncKeys keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('allreader-mcp-cache');
    store = MirrorStore(dir);
    keys = await SyncKeys.derive(MasterKey.generate());
  });
  tearDown(() => dir.delete(recursive: true));

  /// A mirror with no backend — nothing here pulls, it only saves and loads.
  LibraryMirror mirrorWith({
    required int cursor,
    required List<MirroredItem> items,
  }) =>
      LibraryMirror(backend: _NoBackend(), keys: keys)
        ..restore(cursor: cursor, items: items);

  group('keeping the mirror between runs', () {
    test('what was saved comes back', () async {
      await store.save(mirrorWith(cursor: 42, items: [
        MirroredItem(
          id: 'i1',
          seq: 42,
          title: 'The harbour ledgers',
          source: 'Example Post',
          summary: 'Two ledgers disagreed.',
          at: DateTime.utc(2026, 8, 3),
        ),
      ]));

      final restored = mirrorWith(cursor: 0, items: const []);
      await store.restore(restored);

      expect(restored.cursor, 42);
      final item = restored.items.single;
      expect(item.title, 'The harbour ledgers');
      expect(item.summary, 'Two ledgers disagreed.');
      expect(item.at, DateTime.utc(2026, 8, 3));
    });

    test('the cursor comes back with its items, never alone', () async {
      // A cursor without its items would skip the log entries that built
      // them, leaving a mirror permanently missing everything from before the
      // restart, and never noticing.
      await store.save(mirrorWith(cursor: 99, items: [
        const MirroredItem(id: 'i1', seq: 99, title: 'Kept'),
      ]));

      final restored = mirrorWith(cursor: 0, items: const []);
      await store.restore(restored);

      expect(restored.cursor, 99);
      expect(restored.items, isNotEmpty);
    });

    test('nothing saved yet is simply an empty mirror', () async {
      final restored = mirrorWith(cursor: 0, items: const []);
      await store.restore(restored);
      expect(restored.cursor, 0);
      expect(restored.items, isEmpty);
    });
  });

  group('a cache that cannot be read', () {
    /// Every one of these means the same thing: read the log again, which
    /// always works. None of them may throw, because a cache is never a
    /// source of truth.
    test('a corrupt file is treated as empty', () async {
      await File('${dir.path}/mirror.json').writeAsString('{not json');

      final restored = mirrorWith(cursor: 7, items: const []);
      await store.restore(restored);
      expect(restored.cursor, 7, reason: 'left as it was, not thrown over');
    });

    test('a future format is treated as empty', () async {
      await File('${dir.path}/mirror.json')
          .writeAsString(jsonEncode({'version': 99, 'cursor': 5}));

      final restored = mirrorWith(cursor: 0, items: const []);
      await store.restore(restored);
      expect(restored.cursor, 0);
    });

    test('an entry with no id is skipped, and the rest survive', () async {
      await File('${dir.path}/mirror.json').writeAsString(jsonEncode({
        'version': 1,
        'cursor': 3,
        'items': [
          {'seq': 1, 'title': 'Nameless'},
          {'id': 'i2', 'seq': 3, 'title': 'Fine'},
        ],
      }));

      final restored = mirrorWith(cursor: 0, items: const []);
      await store.restore(restored);
      expect(restored.items.single.id, 'i2');
    });
  });

  group('writing it', () {
    test('leaves no half-written file behind', () async {
      // Written to a temporary name and renamed, so a process that dies
      // mid-write leaves the previous cache rather than a broken one.
      await store.save(mirrorWith(cursor: 1, items: const []));

      final leftovers = await dir
          .list()
          .map((e) => e.path.split('/').last)
          .where((name) => name != 'mirror.json')
          .toList();
      expect(leftovers, isEmpty);
    });

    test('a second save replaces the first', () async {
      await store.save(mirrorWith(cursor: 1, items: const []));
      await store.save(mirrorWith(cursor: 2, items: [
        const MirroredItem(id: 'i1', seq: 2),
      ]));

      final restored = mirrorWith(cursor: 0, items: const []);
      await store.restore(restored);
      expect(restored.cursor, 2);
      expect(restored.items, hasLength(1));
    });
  });
}

/// The mirror needs a backend to construct and never uses it here: saving and
/// restoring touch neither the network nor the keys, which is why they can be
/// tested without either.
class _NoBackend implements SyncBackend {
  Never _unused() => throw StateError('not used by save or restore');

  @override
  Future<int> append(String payload) => _unused();
  @override
  Future<List<SyncEntry>> readFrom(int seq, {int limit = 100}) => _unused();
  @override
  Future<void> putBlob(String name, String payload) => _unused();
  @override
  Future<String> getBlob(String name) => _unused();
  @override
  Future<int> subscribe() => _unused();
  @override
  Future<BackendInstance> instance() => _unused();
}
