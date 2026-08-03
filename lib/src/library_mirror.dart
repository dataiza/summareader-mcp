import 'dart:convert';

import 'package:allreader_core/allreader_core.dart';

/// One item, as this server knows it.
///
/// Deliberately thin. The sync log carries whatever the app decided to
/// replicate, and this mirrors it rather than modelling it — a second schema
/// here would be a second thing to keep in step with the app's.
class MirroredItem {
  const MirroredItem({
    required this.id,
    required this.seq,
    this.title,
    this.source,
    this.url,
    this.summary,
    this.at,
  });

  final String id;

  /// Where in the log this version came from. The highest one wins, which is
  /// the same last-writer-wins rule the app applies.
  final int seq;

  final String? title;
  final String? source;
  final String? url;
  final String? summary;
  final DateTime? at;

  MirroredItem mergedWith(MirroredItem newer) => MirroredItem(
        id: id,
        seq: newer.seq,
        // Field by field, so an entry that only carries a summary does not
        // erase a title that arrived earlier.
        title: newer.title ?? title,
        source: newer.source ?? source,
        url: newer.url ?? url,
        summary: newer.summary ?? summary,
        at: newer.at ?? at,
      );
}

/// A decrypted copy of the library, built from the sync log.
///
/// This is the part that makes an MCP server possible and the part that makes
/// it dangerous: the sync server holds ciphertext and cannot read any of
/// this, and this process holds the keys and can read all of it. Everything
/// here is therefore a **cache** — rebuildable from the log, safe to delete,
/// and never the only copy of anything.
class LibraryMirror {
  LibraryMirror({required this.backend, required this.keys});

  final SyncBackend backend;
  final SyncKeys keys;

  final _items = <String, MirroredItem>{};

  /// The last sequence number applied. Persisted by the caller so a restart
  /// resumes rather than re-reading the whole log.
  int cursor = 0;

  Iterable<MirroredItem> get items => _items.values;

  /// Reads everything new and decrypts it.
  ///
  /// An entry that will not decrypt is skipped rather than fatal: one bad
  /// record must not stop the other thousand, and on a log written by a newer
  /// app version "cannot read this" is an expected answer rather than a bug.
  Future<int> pull({int limit = 500}) async {
    var applied = 0;

    while (true) {
      final entries = await backend.readFrom(cursor, limit: limit);
      if (entries.isEmpty) break;

      for (final entry in entries) {
        cursor = entry.seq > cursor ? entry.seq : cursor;
        final item = await _decode(entry);
        if (item == null) continue;

        final existing = _items[item.id];
        _items[item.id] =
            existing == null ? item : existing.mergedWith(item);
        applied++;
      }

      if (entries.length < limit) break;
    }

    return applied;
  }

  Future<MirroredItem?> _decode(SyncEntry entry) async {
    try {
      final opened = await Envelope.openText(
        SealedBlob.fromWire(entry.payload),
        keys.logEntries,
      );
      if (opened == null) return null;

      final decoded = jsonDecode(opened);
      if (decoded is! Map<String, dynamic>) return null;

      final id = decoded['id'];
      if (id is! String || id.isEmpty) return null;

      return MirroredItem(
        id: id,
        seq: entry.seq,
        title: _string(decoded['title']),
        source: _string(decoded['source']),
        url: _string(decoded['url']),
        summary: _string(decoded['tldr']) ?? _string(decoded['summary']),
        at: DateTime.tryParse(_string(decoded['at']) ?? ''),
      );
    } catch (_) {
      // Unreadable is a state, not a failure. See above.
      return null;
    }
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Everything whose text mentions [needle], newest first.
  ///
  /// A substring match over what has been decrypted, which is all a server
  /// holding no index can honestly offer for now.
  List<MirroredItem> search(String needle, {int limit = 20}) {
    final lower = needle.toLowerCase();
    final hits = _items.values.where((item) {
      return [item.title, item.source, item.summary, item.url]
          .whereType<String>()
          .any((field) => field.toLowerCase().contains(lower));
    }).toList()
      ..sort((a, b) => b.seq.compareTo(a.seq));

    return hits.take(limit).toList();
  }
}
