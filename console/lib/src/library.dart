/// The library, wherever it is — a file on this machine, or a mirror over
/// there.
///
/// Two implementations of one small reading surface, the same shape the
/// Python side has in `store.py` and `store/remote.py`: the console takes
/// whichever it is handed and the widgets never ask which one they got.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import 'query.dart';

/// One row of the results list. Three columns are drawn from it — the date,
/// the source and the title — and the rest is what a later pane would need.
class Item {
  const Item({
    required this.id,
    required this.title,
    required this.source,
    required this.url,
    this.published,
    this.read = false,
  });

  final String id;
  final String title;
  final String source;
  final String url;
  final DateTime? published;
  final bool read;

  /// The date as the rest of the project prints it: UTC, because the stored
  /// instant is UTC and a local rendering would move an article across the
  /// date line depending on who is looking.
  String get when => published == null
      ? ''
      : '${published!.year.toString().padLeft(4, '0')}-'
            '${published!.month.toString().padLeft(2, '0')}-'
            '${published!.day.toString().padLeft(2, '0')}';
}

abstract class LibrarySource {
  Future<List<Item>> search(String query, {int limit = 200});

  Future<Map<String, int>> counts();

  /// Only `sync.cursor` is ever asked for, which is the one setting that is a
  /// fact about the library rather than about the mirror's bookkeeping.
  Future<String?> setting(String key);

  void close();
}

/// The mirror's own file, read directly.
///
/// The library is right here and this console is already the machine that
/// holds it, so a port, a token and a serialization step would all be
/// ceremony. SQLite is in WAL with a busy timeout precisely so a reader and a
/// writer can coexist — which `serve` has always relied on — and that is what
/// makes reading the file underneath a running server uneventful rather than
/// a lock somebody sees once a week.
class LocalLibrary implements LibrarySource {
  LocalLibrary._(this._db);

  /// [readOnly] is `--library` mode: the app may be running against that file
  /// and a mirror has no business writing to a library it does not own.
  ///
  /// The mirror's own file is opened for writing even though nothing here
  /// writes: a read-only connection to a WAL database needs the shared-memory
  /// file, and cannot make one — so on a mirror that has been stopped since
  /// its last checkpoint, read-only is "unable to open database file" rather
  /// than an empty pane.
  factory LocalLibrary.open(String path, {bool readOnly = false}) {
    final db = sqlite3.open(
      path,
      mode: readOnly ? OpenMode.readOnly : OpenMode.readWrite,
    );
    db.execute('PRAGMA busy_timeout = 5000');
    // The word-boundary match the CLI's `search` uses, registered here so the
    // SQL below can be the same SQL. Without it every query against this file
    // is "no such function: word_start", and with a different match written in
    // Dart the console would quietly answer a different question than the
    // command line does.
    db.createFunction(
      functionName: 'word_start',
      argumentCount: const AllowedArgumentCount(2),
      deterministic: true,
      function: (args) => _wordStart(args[0] as String?, args[1] as String?),
    );
    return LocalLibrary._(db);
  }

  final Database _db;

  @override
  Future<List<Item>> search(String query, {int limit = 200}) async {
    final where = <String>[];
    final args = <Object?>[];
    // The same box the terminal interface has: words, and the fields around
    // them. Clause for clause with `Store.search` in store.py, because two
    // answers to one query is worse than one wrong answer.
    final (needle, filters) = parseQuery(query);
    if (needle.isNotEmpty) {
      // Cheapest column first: an OR stops at the first branch that says yes,
      // and a title is a line where a body is an article.
      final parts = <String>[];
      for (final column in [
        'i.title',
        'src.name',
        'i.canonical_url',
        's.text',
        't.text',
      ]) {
        final (clause, clauseArgs) = _matches(column, needle);
        parts.add(clause);
        args.addAll(clauseArgs);
      }
      where.add('(${parts.join(' OR ')})');
    }

    if (filters.title != null) {
      final (clause, clauseArgs) = _matches('i.title', filters.title!);
      where.add(clause);
      args.addAll(clauseArgs);
    }
    if (filters.source != null) {
      final (clause, clauseArgs) = _matches('src.name', filters.source!);
      where.add(clause);
      args.addAll(clauseArgs);
    }
    if (filters.since != null) {
      where.add('coalesce(i.published_at, i.fetched_at) >= ?');
      args.add(filters.since!.millisecondsSinceEpoch ~/ 1000);
    }
    if (filters.until != null) {
      where.add('coalesce(i.published_at, i.fetched_at) <= ?');
      args.add(filters.until!.millisecondsSinceEpoch ~/ 1000);
    }
    if (filters.readSince != null) {
      where.add('i.read_at >= ?');
      args.add(filters.readSince!.millisecondsSinceEpoch ~/ 1000);
    }
    if (filters.readUntil != null) {
      where.add('i.read_at <= ?');
      args.add(filters.readUntil!.millisecondsSinceEpoch ~/ 1000);
    }
    if (filters.unread != null) {
      where.add('i.read = ?');
      args.add(filters.unread! ? 0 : 1);
    }
    if (filters.summarized != null) {
      where.add(filters.summarized! ? 's.text IS NOT NULL' : 's.text IS NULL');
    }
    // An item's own tag, or a tag on any source it arrived from — the rule the
    // app filters by, so all three answer alike. Several tags narrow.
    final wanted = {
      for (final tag in filters.tags)
        if (tag.trim().isNotEmpty) tag.trim().toLowerCase(),
    }.toList()..sort();
    for (final tag in wanted) {
      where.add(
        '(EXISTS (SELECT 1 FROM item_tags it '
        '          WHERE it.item_id = i.id AND it.tag = ?)'
        ' OR EXISTS (SELECT 1 FROM item_channels ic '
        '              JOIN channel_tags ct ON ct.channel_id = ic.channel_id '
        '             WHERE ic.item_id = i.id AND ct.tag = ?))',
      );
      args.addAll([tag, tag]);
    }

    final sql =
        '''
      SELECT i.id, i.title, i.canonical_url, i.published_at, i.fetched_at,
             i.read, src.name AS source
      FROM items i
      $_sourceJoin
      $_summaryJoin
      LEFT JOIN extracted_texts t ON t.item_id = i.id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY coalesce(i.published_at, i.fetched_at) DESC
      LIMIT ?
    ''';
    return [
      for (final row in _db.select(sql, [...args, limit]))
        Item(
          id: row['id'] as String,
          title: (row['title'] as String?) ?? '(untitled)',
          source: (row['source'] as String?) ?? '',
          url: (row['canonical_url'] as String?) ?? '',
          published: _when(row['published_at'] ?? row['fetched_at']),
          read: (row['read'] as int? ?? 0) != 0,
        ),
    ];
  }

  @override
  Future<Map<String, int>> counts() async {
    final row = _db.select('''
      SELECT (SELECT COUNT(*) FROM items) AS items,
             (SELECT COUNT(*) FROM items WHERE read = 0) AS unread,
             (SELECT COUNT(DISTINCT item_id) FROM summaries
              WHERE state = 'ok' AND text IS NOT NULL) AS summarized,
             (SELECT COUNT(*) FROM extracted_texts) AS bodies,
             (SELECT COUNT(*) FROM channels WHERE kind <> 'saved') AS sources,
             -- When this library last took delivery of anything. There is no
             -- column recording the pull itself — the schema is a subset of
             -- the app's and the app has no pulls — so this is the newest
             -- instant carried by the data that arrived: an article's fetch,
             -- the moment a read mark landed here, a summary's creation.
             -- Chosen over any one of the three because a library that has
             -- only been catching up on read marks for a week has a stale
             -- fetched_at and is emphatically not idle.
             (SELECT MAX(t) FROM (
                SELECT MAX(fetched_at) AS t FROM items
                UNION ALL SELECT MAX(read_at) FROM items
                UNION ALL SELECT MAX(created_at) FROM summaries
              )) AS synced
    ''').first;
    return {
      for (final key in ['items', 'unread', 'summarized', 'bodies', 'sources'])
        key: (row[key] as int?) ?? 0,
      // Absent rather than zero on an empty library: zero is 1970, and the
      // pane has to be able to tell "nothing has ever arrived" from a date.
      if (row['synced'] case final int synced) 'synced': synced,
    };
  }

  @override
  Future<String?> setting(String key) async {
    try {
      final rows = _db.select('SELECT value FROM settings WHERE key = ?', [
        key,
      ]);
      return rows.isEmpty ? null : rows.first['value'] as String?;
    } on SqliteException {
      // `--library` mode against the app's own database, whose settings table
      // holds the app's keys and not ours.
      return null;
    }
  }

  @override
  void close() => _db.dispose();
}

DateTime? _when(Object? seconds) => seconds is int
    ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
    : null;

/// A word-start match on one column, with a cheap LIKE ahead of it.
///
/// `word_start` calls back out of SQLite once per row per column — over whole
/// summaries and article bodies that call *is* the search, and no index can
/// help a function. LIKE is strictly wider than a word-start match and runs in
/// C, so asking it first leaves the callback only the rows already holding the
/// needle. The same two-step, in the same order, as `store.py`.
///
/// ponytail: LIKE folds case over ASCII only, so a non-ASCII needle skips the
/// prefilter rather than quietly losing matches. FTS5 is the upgrade path if
/// the fast path stops being fast.
(String, List<Object?>) _matches(String column, String needle) {
  final ascii = needle.codeUnits.every((unit) => unit < 128);
  if (!ascii) return ('word_start($column, ?)', [needle]);
  final like =
      '%${needle.replaceAllMapped(RegExp(r'([\\%_])'), (m) => '\\${m[1]}')}%';
  return (
    "($column LIKE ? ESCAPE '\\' AND word_start($column, ?))",
    [like, needle],
  );
}

/// True when the needle appears in the haystack starting at a word start.
///
/// A word start is "not preceded by a word character", which is what makes
/// `rust` find "Rust", "rustc" and "Rust:" while leaving "trust" alone. `\b`
/// would be wrong for a needle beginning with punctuation, where there is no
/// boundary to find; this asks about the character before instead.
///
/// Spelled out as a class rather than as `\w` because Dart's `\w` is ASCII
/// even with the unicode flag, while the Python side's is not — and an
/// ASCII-only rule would find "Wéber" inside "Zwéber" and disagree with the
/// command line on exactly the libraries that are not in English.
int _wordStart(String? haystack, String? needle) {
  if (haystack == null || needle == null || needle.isEmpty) return 0;
  return _needle(needle).hasMatch(haystack) ? 1 : 0;
}

final _needles = <String, RegExp>{};

RegExp _needle(String needle) => _needles.putIfAbsent(
  needle,
  () => RegExp(
    r'(?<![\p{L}\p{N}_])' + RegExp.escape(needle),
    caseSensitive: false,
    unicode: true,
  ),
);

// The source is the earliest non-saved membership, named by its title falling
// back to its address — the same fallback the app's shelf uses.
const _sourceJoin = '''
  LEFT JOIN (
    SELECT ic.item_id, coalesce(c.title, c.url) AS name,
           ROW_NUMBER() OVER (PARTITION BY ic.item_id
                              ORDER BY ic.first_seen_at, c.id) AS rn
    FROM item_channels ic
    JOIN channels c ON c.id = ic.channel_id
    WHERE c.kind <> 'saved'
  ) src ON src.item_id = i.id AND src.rn = 1
''';

// Newest summary wins when several models have had a go at the same item. A
// failed or half-written row is not a summary: the app stores those here too,
// so a mirror reading its file must say which it means.
const _summaryJoin = '''
  LEFT JOIN (
    SELECT item_id, text,
           ROW_NUMBER() OVER (PARTITION BY item_id
                              ORDER BY created_at DESC) AS rn
    FROM summaries
    WHERE state = 'ok' AND text IS NOT NULL
  ) s ON s.item_id = i.id AND s.rn = 1
''';

/// The same library, read over the port instead of out of the file.
///
/// `--remote`: a console on a laptop against a mirror on the box that is
/// allowed to hold the plaintext. It speaks the MCP tools the server already
/// publishes — `search_library` and `library_summary` — because the point of
/// this mode is that no new endpoint had to exist for it.
class RemoteLibrary implements LibrarySource {
  RemoteLibrary(String url, {this.token, http.Client? client})
    : url = _mcpUrl(url),
      _client = client ?? http.Client();

  /// `/mcp` is where the transport lives, and leaving it off is the obvious
  /// thing to type. Adding it back beats a 404 that says nothing about which
  /// half of the address was wrong.
  static String _mcpUrl(String url) {
    final trimmed = url.replaceAll(RegExp(r'/+$'), '');
    return trimmed.endsWith('/mcp') ? trimmed : '$trimmed/mcp';
  }

  final String url;
  final String? token;
  final http.Client _client;

  String? _session;
  int _id = 0;

  @override
  Future<List<Item>> search(String query, {int limit = 200}) async {
    // The tool caps what it will return at a hundred; asking for more is a
    // number the far end quietly ignores, so the console asks for what it can
    // have rather than showing a limit it does not get.
    // Parsed here rather than sent whole: the tool takes the fields as
    // arguments, and a mirror one release older would search for the literal
    // text "since:7d" if the box were forwarded verbatim.
    final (needle, filters) = parseQuery(query);
    final payload = await _call('search_library', {
      'query': needle,
      ...filters.toToolArguments(),
      'limit': limit > 100 ? 100 : limit,
    });
    return [
      for (final row in (payload['items'] as List? ?? const []))
        Item(
          id: row['id'] as String? ?? '',
          title: row['title'] as String? ?? '(untitled)',
          source: row['source'] as String? ?? '',
          url: row['url'] as String? ?? '',
          published: DateTime.tryParse(row['published'] as String? ?? '')
              ?.toUtc(),
          read: row['read'] == true,
        ),
    ];
  }

  @override
  Future<Map<String, int>> counts() async {
    final payload = await _call('library_summary', const {});
    return {
      for (final key in ['items', 'unread', 'summarized', 'bodies', 'sources'])
        key: (payload[key] as num?)?.toInt() ?? 0,
    };
  }

  @override
  Future<String?> setting(String key) async {
    if (key != 'sync.cursor') return null;
    final payload = await _call('library_summary', const {});
    return '${(payload['cursor'] as num?)?.toInt() ?? 0}';
  }

  @override
  void close() => _client.close();

  // ---- the wire --------------------------------------------------------

  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, Object?> arguments,
  ) async {
    if (_session == null) await _initialize();
    final result = await _rpc('tools/call', {
      'name': tool,
      'arguments': arguments,
    });
    if (result['isError'] == true) {
      throw StateError('$tool: ${_text(result)}');
    }
    // The tools are annotated `-> dict`, which is not specific enough for an
    // output schema, so there is usually no structured content and the dict
    // arrives as JSON in a text block. Both are read: a server that grows a
    // schema later should not break a console that only knew the old spelling.
    final structured = result['structuredContent'];
    if (structured is Map<String, dynamic>) return structured;
    final decoded = jsonDecode(_text(result));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('$tool: answered with something that is not an object');
    }
    return decoded;
  }

  String _text(Map<String, dynamic> result) => [
    for (final block in (result['content'] as List? ?? const []))
      if (block is Map && block['text'] is String) block['text'] as String,
  ].join(' ');

  Future<void> _initialize() async {
    final result = await _rpc('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, Object>{},
      'clientInfo': {'name': 'summareader-mcp-console', 'version': '0.2.0'},
    });
    if (result.isEmpty) throw StateError('$url: no answer to initialize');
    // The server will not answer a tool call from a session it has not been
    // told is ready.
    await _post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
  }

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, Object?> params,
  ) async {
    final response = await _post({
      'jsonrpc': '2.0',
      'id': ++_id,
      'method': method,
      'params': params,
    });
    final body = _envelope(response);
    if (body == null) return const {};
    final error = body['error'];
    if (error is Map) throw StateError('$url: ${error['message']}');
    return (body['result'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<http.Response> _post(Map<String, Object?> message) async {
    final response = await _client.post(
      Uri.parse(url),
      headers: {
        'content-type': 'application/json',
        // Either shape is acceptable to this console; the server picks, and
        // the Python one picks the event stream.
        'accept': 'application/json, text/event-stream',
        if (token != null) 'authorization': 'Bearer $token',
        'mcp-session-id': ?_session,
      },
      body: jsonEncode(message),
    );
    if (response.statusCode == 401) {
      throw StateError(
        '$url: refused. If the mirror sets bearer_token, the console needs it '
        'in SUMMAREADER_MCP_TOKEN.',
      );
    }
    if (response.statusCode >= 400) {
      throw StateError('$url: ${response.statusCode} ${response.reasonPhrase}');
    }
    _session ??= response.headers['mcp-session-id'];
    return response;
  }

  /// The JSON-RPC message out of whichever envelope came back.
  ///
  /// A streamable-HTTP server may answer one request with a plain JSON body or
  /// with an event stream carrying the same object; both are legal and the
  /// choice is the server's, so the console reads either rather than depending
  /// on today's answer.
  Map<String, dynamic>? _envelope(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    if (body.trim().isEmpty) return null;
    final type = response.headers['content-type'] ?? '';
    if (!type.contains('event-stream')) {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    for (final line in const LineSplitter().convert(body)) {
      if (!line.startsWith('data:')) continue;
      final decoded = jsonDecode(line.substring(5).trim());
      if (decoded is Map<String, dynamic>) return decoded;
    }
    return null;
  }
}
