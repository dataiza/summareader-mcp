/// One box, and the fields people type into it.
///
/// The terminal interface has taken `source:"Colion Noir" title:rust since:7d
/// unread:yes` since it was written; the window took words and nothing else,
/// so the same query typed here found nothing and said nothing about why.
/// This is `parse_query` from `summareader_mcp/tools.py`, in Dart, field for
/// field — two spellings of one search is a thing to learn twice.
library;

/// What was asked for, apart from the words.
class QueryFilters {
  const QueryFilters({
    this.title,
    this.source,
    this.since,
    this.until,
    this.readSince,
    this.readUntil,
    this.unread,
    this.summarized,
    this.tags = const [],
  });

  final String? title;
  final String? source;
  final DateTime? since;
  final DateTime? until;
  final DateTime? readSince;
  final DateTime? readUntil;
  final bool? unread;
  final bool? summarized;

  /// Repeatable and narrowing: `tag:linux tag:kernel` wants both, the same as
  /// it does in the app.
  final List<String> tags;

  bool get isEmpty =>
      title == null &&
      source == null &&
      since == null &&
      until == null &&
      readSince == null &&
      readUntil == null &&
      unread == null &&
      summarized == null &&
      tags.isEmpty;

  /// The names the MCP tool knows, for a mirror being read over its port.
  Map<String, Object?> toToolArguments() => {
    if (title != null) 'title': title,
    if (source != null) 'source': source,
    if (since != null) 'since': since!.toIso8601String(),
    if (until != null) 'until': until!.toIso8601String(),
    if (readSince != null) 'read_since': readSince!.toIso8601String(),
    if (readUntil != null) 'read_until': readUntil!.toIso8601String(),
    if (unread != null) 'unread': unread,
    if (summarized != null) 'summarized': summarized,
    if (tags.isNotEmpty) 'tags': tags,
  };
}

/// Thrown when a date cannot be read. The message is what to type instead.
class BadSince implements Exception {
  const BadSince(this.message);
  final String message;
  @override
  String toString() => message;
}

const _aliases = {
  'feed': 'source',
  'read': 'read_since',
  'read_after': 'read_since',
  'read_before': 'read_until',
  'before': 'until',
  'after': 'since',
};
const _dates = {'since', 'until', 'read_since', 'read_until'};
const _flags = {'unread', 'summarized'};
const _no = {'no', 'false', '0', 'off'};

final _field = RegExp(r'\b(\w+):\s*("[^"]*"|\S+)');
final _relative = RegExp(r'^(\d+)\s*([hdw])$');

/// `3h`, `7d`, `3w`, or a date — one reading of it here, the CLI and MCP.
///
/// Hours are in it because "what arrived this morning" is the question a
/// reading library gets asked most, and a day was the finest it could say.
DateTime parseSince(String value) {
  final trimmed = value.trim().toLowerCase();
  final relative = _relative.firstMatch(trimmed);
  if (relative != null) {
    const hours = {'h': 1, 'd': 24, 'w': 168};
    final count = int.parse(relative.group(1)!);
    return DateTime.now().toUtc().subtract(
      Duration(hours: hours[relative.group(2)]! * count),
    );
  }
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) {
    throw BadSince('$value: expected 3h, 7d, or a date like 2026-08-01');
  }
  return parsed.isUtc
      ? parsed
      : DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
        );
}

/// Splits what was typed into words and fields.
///
/// Anything that is not a field this knows stays part of the words, so a colon
/// in a title costs a search rather than an error.
(String, QueryFilters) parseQuery(String text) {
  String? title;
  String? source;
  DateTime? since;
  DateTime? until;
  DateTime? readSince;
  DateTime? readUntil;
  bool? unread;
  bool? summarized;
  final tags = <String>[];

  var rest = text;
  for (final match in _field.allMatches(text)) {
    final raw = match.group(1)!.toLowerCase();
    final key = _aliases[raw] ?? raw;
    final value = match.group(2)!.replaceAll('"', '');

    if (_dates.contains(key)) {
      final when = parseSince(value);
      switch (key) {
        case 'since':
          since = when;
        case 'until':
          until = when;
        case 'read_since':
          readSince = when;
        case 'read_until':
          readUntil = when;
      }
    } else if (_flags.contains(key)) {
      final yes = !_no.contains(value.toLowerCase());
      if (key == 'unread') {
        unread = yes;
      } else {
        summarized = yes;
      }
    } else if (key == 'tag') {
      tags.add(value);
    } else if (key == 'source') {
      source = value;
    } else if (key == 'title') {
      title = value;
    } else {
      continue;
    }
    rest = rest.replaceFirst(match.group(0)!, ' ');
  }

  return (
    rest.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).join(' '),
    QueryFilters(
      title: title,
      source: source,
      since: since,
      until: until,
      readSince: readSince,
      readUntil: readUntil,
      unread: unread,
      summarized: summarized,
      tags: tags,
    ),
  );
}
