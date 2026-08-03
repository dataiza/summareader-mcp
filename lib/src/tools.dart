import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'library_mirror.dart';

/// The tools this server offers over MCP.
///
/// Read-only, deliberately, for as long as this is a prototype. A tool that
/// writes to the log would be a second writer of a format the app owns, and
/// getting that wrong corrupts a library rather than returning a bad answer.
///
/// Every tool answers from the mirror — the decrypted local copy — and never
/// from the sync server directly. The server has nothing readable to give.
class LibraryTools {
  LibraryTools(this.mirror);

  final LibraryMirror mirror;

  void registerOn(McpServer server) {
    server.registerTool(
      'search_library',
      description:
          'Search the reading library by title, source, summary or address. '
          'Returns matching items, newest first.',
      inputSchema: JsonSchema.object(
        properties: {
          'query': JsonSchema.string(),
          'limit': JsonSchema.number(),
        },
        required: ['query'],
      ),
      callback: (args, extra) async {
        final query = '${args['query'] ?? ''}'.trim();
        if (query.isEmpty) {
          return _text('A query is needed. Ask for a word or a phrase.');
        }
        final limit = _limit(args['limit']);
        final hits = mirror.search(query, limit: limit);

        return _text(hits.isEmpty
            ? 'Nothing in the library mentions "$query".'
            : _describe(hits));
      },
    );

    server.registerTool(
      'recent_items',
      description:
          'The most recently synced items in the reading library, whether or '
          'not they have been summarized.',
      inputSchema: JsonSchema.object(
        properties: {'limit': JsonSchema.number()},
      ),
      callback: (args, extra) async {
        final limit = _limit(args['limit']);
        final recent = mirror.items.toList()
          ..sort((a, b) => b.seq.compareTo(a.seq));

        return _text(recent.isEmpty
            ? 'The library is empty, or nothing has synced yet.'
            : _describe(recent.take(limit).toList()));
      },
    );

    server.registerTool(
      'library_summary',
      description:
          'How much is in the library and how much of it has been '
          'summarized. Useful before asking for a report over it.',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async {
        final all = mirror.items.toList();
        final summarized = all.where((i) => i.summary != null).length;
        final sources = all
            .map((i) => i.source)
            .whereType<String>()
            .toSet()
            .length;

        return _text(all.isEmpty
            ? 'Nothing has synced yet.'
            : '${all.length} items from $sources sources. '
                '$summarized have a summary, ${all.length - summarized} do '
                'not. Read up to entry ${mirror.cursor} of the sync log.');
      },
    );
  }

  /// Bounded, because a tool that can be asked for everything will be.
  static int _limit(Object? raw) {
    final asked = raw is num ? raw.toInt() : 20;
    return asked.clamp(1, 100);
  }

  /// JSON rather than prose: the caller is a model, and a model given a table
  /// of fields does better than one given a paragraph it has to parse back.
  static CallToolResult _text(String text) =>
      CallToolResult.fromContent([TextContent(text: text)]);

  static String _describe(List<MirroredItem> items) {
    return const JsonEncoder.withIndent('  ').convert([
      for (final item in items)
        {
          'id': item.id,
          if (item.title != null) 'title': item.title,
          if (item.source != null) 'source': item.source,
          if (item.url != null) 'url': item.url,
          if (item.summary != null) 'summary': item.summary,
          if (item.at != null) 'at': item.at!.toIso8601String(),
        },
    ]);
  }
}
