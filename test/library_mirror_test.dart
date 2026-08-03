import 'dart:convert';

import 'package:allreader_core/allreader_core.dart';
import 'package:allreader_mcp/src/library_mirror.dart';
import 'package:test/test.dart';

/// A sync server that only remembers what it was told.
class FakeBackend implements SyncBackend {
  final entries = <SyncEntry>[];

  @override
  Future<int> append(String payload) async {
    entries.add(SyncEntry(seq: entries.length + 1, payload: payload));
    return entries.length;
  }

  @override
  Future<List<SyncEntry>> readFrom(int seq, {int limit = 100}) async =>
      entries.where((e) => e.seq > seq).take(limit).toList();

  @override
  Future<void> putBlob(String name, String payload) async {}
  @override
  Future<String> getBlob(String name) async => '';
  @override
  Future<int> subscribe() async => entries.length;
  @override
  Future<BackendInstance> instance() async => const BackendInstance(
        instanceId: 'fake',
        software: 'test',
      );
}

void main() {
  late FakeBackend backend;
  late SyncKeys keys;
  late LibraryMirror mirror;

  setUp(() async {
    backend = FakeBackend();
    keys = await SyncKeys.derive(await MasterKey.generate());
    mirror = LibraryMirror(backend: backend, keys: keys);
  });

  /// Writes an entry the way the app does: JSON, sealed, packed to the wire.
  Future<void> write(Map<String, Object?> item) async {
    final sealed = await Envelope.sealText(jsonEncode(item), keys.logEntries);
    await backend.append(sealed.toWire());
  }

  group('reading the log', () {
    test('decrypts what was written and keeps it', () async {
      await write({
        'id': 'i1',
        'title': 'The harbour ledgers',
        'source': 'Example Post',
      });

      expect(await mirror.pull(), 1);
      expect(mirror.items.single.title, 'The harbour ledgers');
    });

    test('a second read starts where the first stopped', () async {
      await write({'id': 'i1', 'title': 'One'});
      await mirror.pull();

      await write({'id': 'i2', 'title': 'Two'});
      expect(await mirror.pull(), 1, reason: 'only the new one');
      expect(mirror.items.length, 2);
    });

    test('a later entry updates an item field by field', () async {
      // An entry carrying only a summary must not erase the title that
      // arrived with the first one.
      await write({'id': 'i1', 'title': 'One', 'source': 'Example'});
      await write({'id': 'i1', 'tldr': 'The short version.'});
      await mirror.pull();

      final item = mirror.items.single;
      expect(item.title, 'One');
      expect(item.source, 'Example');
      expect(item.summary, 'The short version.');
    });
  });

  group('what cannot be read', () {
    test('an entry sealed with another key is skipped, not fatal', () async {
      // What a device that has not been given the master key sees, and what
      // any observer of the server sees. One unreadable entry must not stop
      // the thousand around it.
      final stranger = await SyncKeys.derive(await MasterKey.generate());
      final sealed = await Envelope.sealText('{"id":"x"}', stranger.logEntries);
      await backend.append(sealed.toWire());
      await write({'id': 'i1', 'title': 'Readable'});

      expect(await mirror.pull(), 1);
      expect(mirror.items.single.id, 'i1');
    });

    test('malformed wire bytes are skipped too', () async {
      await backend.append('not.valid.base64!!');
      await write({'id': 'i1', 'title': 'Readable'});

      expect(await mirror.pull(), 1);
    });

    test('an entry with no id is not an item', () async {
      await write({'title': 'Nameless'});
      expect(await mirror.pull(), 0);
    });
  });

  group('searching what has been decrypted', () {
    setUp(() async {
      await write({'id': 'i1', 'title': 'Kernel soundness', 'tldr': 'A bug.'});
      await write({'id': 'i2', 'title': 'Harbour ledgers', 'source': 'Post'});
      await mirror.pull();
    });

    test('matches a title', () {
      expect(mirror.search('harbour').single.id, 'i2');
    });

    test('matches a summary, and ignores case', () {
      expect(mirror.search('A BUG').single.id, 'i1');
    });

    test('finds nothing when there is nothing', () {
      expect(mirror.search('nonexistent'), isEmpty);
    });
  });
}
