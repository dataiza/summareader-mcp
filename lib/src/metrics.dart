import 'dart:io';

import 'library_mirror.dart';

/// What this process can say about itself, in the Prometheus text format.
///
/// **The mirror is a cache, and these are cache numbers.** How much of the log
/// has been read, how many articles that produced, how many of them carry a
/// summary — the questions that answer "is the mirror keeping up", which is
/// the only operational question this process has.
///
/// Nothing here names an article. This is the one process that holds the
/// library in plaintext, and a label carrying a title would put it somewhere
/// nobody expects to find it. Counts and ages only.
String mcpMetrics(LibraryMirror mirror) {
  final out = StringBuffer();

  void metric(String name, String help, String kind, num value,
      [String labels = '']) {
    out
      ..writeln('# HELP $name $help')
      ..writeln('# TYPE $name $kind')
      ..writeln('$name$labels $value');
  }

  final items = mirror.items.toList();
  metric('summareader_mcp_items', 'Articles in the mirror.', 'gauge',
      items.length);
  metric(
    'summareader_mcp_items_summarized',
    'Articles whose summary has arrived.',
    'gauge',
    items.where((item) => (item.summary ?? '').isNotEmpty).length,
  );
  metric('summareader_mcp_cursor', 'How far through the log this mirror is.',
      'gauge', mirror.cursor);

  // The freshest thing it holds. A mirror that stops advancing looks exactly
  // like a quiet library until this number starts growing.
  final newest = items
      .map((item) => item.at)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
  if (newest != null) {
    metric(
      'summareader_mcp_newest_item_age_seconds',
      'How old the most recent article in the mirror is.',
      'gauge',
      DateTime.now().difference(newest).inSeconds,
    );
  }

  metric('summareader_mcp_last_pull_age_seconds',
      'How long ago the mirror last read the log.', 'gauge',
      DateTime.now().difference(lastPull).inSeconds);
  metric('summareader_mcp_pulls_total', 'Reads of the log since start.',
      'counter', pulls);
  metric('summareader_mcp_pull_failures_total',
      'Reads that could not be completed.', 'counter', pullFailures);

  metric('process_start_time_seconds', 'When this process started.', 'gauge',
      started.millisecondsSinceEpoch / 1000);
  metric('process_resident_memory_bytes', 'Memory this process is holding.',
      'gauge', ProcessInfo.currentRss);

  return out.toString();
}

/// When this process came up, so a counter reset reads as a restart.
final started = DateTime.now();

/// The pull loop's own numbers, set by whoever runs it.
DateTime lastPull = DateTime.now();
int pulls = 0;
int pullFailures = 0;
