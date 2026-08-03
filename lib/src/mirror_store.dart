import 'dart:convert';
import 'dart:io';

import 'library_mirror.dart';

/// Keeps the decrypted mirror on disk between runs.
///
/// Without this every start re-reads the whole log and decrypts it again,
/// which is nothing at three entries and minutes at thirty thousand.
///
/// **Plaintext, and deliberately a cache.** Whoever can read this file can
/// read the library, which is the cost of the whole design — so it is written
/// to be safe to delete: losing it costs one re-read, never any data. Nothing
/// here is a source of truth, and nothing should ever be kept only here.
class MirrorStore {
  MirrorStore(this.directory);

  final Directory directory;

  File get _file => File('${directory.path}/mirror.json');

  /// Loads what a previous run left, if anything.
  ///
  /// Anything unreadable is treated as an empty cache rather than an error:
  /// a corrupt file, a half-written one, or one from an older format all mean
  /// the same thing — read the log again, which always works.
  Future<void> restore(LibraryMirror mirror) async {
    try {
      if (!await _file.exists()) return;

      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != 1) return;

      final items = decoded['items'];
      if (items is! List) return;

      mirror.restore(
        cursor: decoded['cursor'] is int ? decoded['cursor'] as int : 0,
        items: [
          for (final raw in items)
            if (raw is Map<String, dynamic>) _itemFrom(raw),
        ].whereType<MirroredItem>().toList(),
      );
    } catch (_) {
      // See above: an unreadable cache is an empty one.
    }
  }

  /// Writes the mirror out.
  ///
  /// Through a temporary file and a rename, because the alternative is a
  /// half-written cache on a process that dies mid-write — which the loader
  /// above would recover from, but by re-reading the whole log, which is the
  /// cost this exists to avoid.
  Future<void> save(LibraryMirror mirror) async {
    await directory.create(recursive: true);
    final temp = File('${_file.path}.writing');

    await temp.writeAsString(jsonEncode({
      'version': 1,
      'cursor': mirror.cursor,
      'items': [
        for (final item in mirror.items)
          {
            'id': item.id,
            'seq': item.seq,
            if (item.title != null) 'title': item.title,
            if (item.source != null) 'source': item.source,
            if (item.url != null) 'url': item.url,
            if (item.summary != null) 'summary': item.summary,
            if (item.at != null) 'at': item.at!.toIso8601String(),
          },
      ],
    }));

    await temp.rename(_file.path);
  }

  static MirroredItem? _itemFrom(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;

    return MirroredItem(
      id: id,
      seq: raw['seq'] is int ? raw['seq'] as int : 0,
      title: raw['title'] as String?,
      source: raw['source'] as String?,
      url: raw['url'] as String?,
      summary: raw['summary'] as String?,
      at: DateTime.tryParse('${raw['at']}'),
    );
  }
}
