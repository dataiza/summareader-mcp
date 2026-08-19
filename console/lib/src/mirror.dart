/// What the console knows, with no widgets involved.
///
/// Everything here is a plain function of its arguments or a thin object over
/// one process, because a window is the part of a program a test cannot look
/// at. The argv, the unit file and the numbers are the parts that go wrong
/// silently — a drifted ExecStart is a service that fails at the next login,
/// in a log nobody has open — so they are asserted here rather than installed
/// and hoped for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const unitName = 'summareader-mcp.service';

/// How often the console asks the server how it is. Two seconds is what a
/// status light has to be to read as a status light rather than as a log.
const pollInterval = Duration(seconds: 2);

/// How to start the mirror.
///
/// The window used to be part of the mirror and could start another copy of
/// itself; this console is a separate program in another language, so it has
/// to find the mirror rather than be it. In order: what the environment says,
/// then whatever sits beside this executable — which is how a bundle ships the
/// two together — and finally the bare name, resolved on PATH, which is what a
/// checkout with the package installed has.
List<String> launcher({Map<String, String>? environment, String? besideMe}) {
  final env = environment ?? Platform.environment;
  final named = env['SUMMAREADER_MCP_EXE'];
  if (named != null && named.isNotEmpty) return [named];
  final beside = besideMe ?? _beside();
  if (beside != null) return [beside];
  return ['summareader-mcp'];
}

String? _beside() {
  final directory = File(Platform.resolvedExecutable).parent.path;
  final name = Platform.isWindows ? 'summareader-mcp.exe' : 'summareader-mcp';
  final candidate = File('$directory/$name');
  return candidate.existsSync() ? candidate.path : null;
}

/// The one spelling of "run the server", shared by the console and the unit.
///
/// HTTP rather than stdio: a supervised server has no MCP client on the other
/// end of its standard input, and the console itself needs the port to ask it
/// anything.
List<String> serveArgv(String host, int port, {List<String>? exe}) => [
  ...(exe ?? launcher()),
  'serve',
  '--transport=http',
  '--host=$host',
  '--port=$port',
];

/// What Start runs — which depends entirely on who owns the server.
///
/// With a unit installed the answer is systemctl and never a child of our own.
/// Two servers on one library both pull, both advance the same cursor and both
/// want the port; the second simply fails to bind, which reads from here as
/// "Start did nothing".
List<String> startCommand({
  required bool managed,
  required String host,
  required int port,
  List<String>? exe,
}) => managed
    ? ['systemctl', '--user', 'start', unitName]
    : serveArgv(host, port, exe: exe);

/// Where systemd looks. XDG_CONFIG_HOME is honoured because systemd does.
String unitPath([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final configured = env['XDG_CONFIG_HOME'];
  final base = (configured == null || configured.isEmpty)
      ? '${env['HOME'] ?? ''}/.config'
      : configured;
  return '$base/systemd/user/$unitName';
}

/// The unit file, as a pure function of what the console was asked for.
///
/// The same unit scripts/summareader-mcp.service describes, written from here
/// rather than by shelling out to scripts/install.sh — a shipped console has
/// no repository beside it, no virtualenv and nothing to pip install. A *user*
/// unit, for the reason that script gives: this holds the master key and a
/// plaintext copy of somebody's library, so it belongs to one person and needs
/// no root to inspect or remove.
///
/// Environment values are quoted because a cache directory with a space in it
/// is unremarkable on a desktop, and unquoted it would silently become two
/// variables, one of them empty.
String renderUnit({
  required String host,
  required int port,
  required String configFile,
  required String cacheDir,
  List<String>? exe,
}) =>
    '''
[Unit]
# Written by the SummaReader mirror's console. Turning off "Start at login"
# there removes this file again.
Description=SummaReader MCP server
Documentation=https://github.com/dataiza/summareader-mcp
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${serveArgv(host, port, exe: exe).join(' ')}
Environment="SUMMAREADER_MCP_CONFIG=$configFile"
Environment="SUMMAREADER_MCP_CACHE=$cacheDir"
Restart=on-failure
RestartSec=5

# This process holds the master key and a plaintext copy of the library — the
# one place in the design where the encryption ends. Everything it does not
# need to touch is closed off.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$cacheDir

[Install]
WantedBy=default.target
''';

/// The address an installed unit serves on.
///
/// So a console opened later reopens on the server that is actually running
/// rather than on its own defaults — which would otherwise show a healthy
/// server as down, on a port nothing answers.
(String, int)? unitBind(String unit) {
  String? host;
  String? port;
  for (final word in unit.split(RegExp(r'\s+'))) {
    if (word.startsWith('--host=')) {
      host = word.substring('--host='.length).replaceAll('"', '');
    } else if (word.startsWith('--port=')) {
      port = word.substring('--port='.length).replaceAll('"', '');
    }
  }
  final number = port == null ? null : int.tryParse(port);
  if (host == null || number == null) return null;
  return (host, number);
}

/// Whether a unit exists, which is the same question as who owns the server.
bool serviceInstalled([Map<String, String>? environment]) =>
    Platform.isLinux && File(unitPath(environment)).existsSync();

/// One command against the user manager, raising what it said when it failed.
///
/// "exit status 1" in a status line tells nobody anything, and this is the one
/// place in the console where the failure is somebody else's to fix.
Future<void> systemctl(List<String> args) async {
  final done = await Process.run('systemctl', ['--user', ...args]);
  if (done.exitCode != 0) {
    final said = '${done.stderr}${done.stdout}'.trim();
    throw StateError(
      said.isEmpty ? 'systemctl --user ${args.join(' ')} failed' : said,
    );
  }
}

/// Write the unit and enable it.
///
/// Writing over an existing one is the update path: a port changed in the
/// console has to reach the unit too, or the service comes back on the old
/// one.
Future<void> installService(
  String unit, {
  Map<String, String>? environment,
  Future<void> Function(List<String>)? manager,
}) async {
  final file = File(unitPath(environment));
  await file.parent.create(recursive: true);
  await file.writeAsString(unit);
  // Defaults to the real user manager, and is replaceable so a test can ask
  // what a rebind leaves on disk without enabling a service on somebody's
  // desktop.
  final run = manager ?? systemctl;
  await run(['daemon-reload']);
  await run(['enable', '--now', unitName]);
}

Future<void> uninstallService([Map<String, String>? environment]) async {
  // Disable before removing: the enable symlink outlives the unit file and
  // leaves systemd complaining about it at every login. Nothing to disable is
  // not a failure — the file going away is what was asked for.
  try {
    await systemctl(['disable', '--now', unitName]);
  } catch (_) {}
  final file = File(unitPath(environment));
  if (file.existsSync()) await file.delete();
  await systemctl(['daemon-reload']);
}

/// One sample out of the Prometheus text format, labelled or not.
///
/// Labelled matters here: the server puts `{instance="…"}` on every sample as
/// soon as a name is configured, so a parser that only matched a bare name
/// would read every number as absent on exactly the installations that
/// bothered to name themselves.
///
/// A dozen lines rather than a Prometheus client dependency, for ten lines of
/// output that the same project also writes.
double? gauge(String text, String name) {
  for (final line in const LineSplitter().convert(text)) {
    if (!line.startsWith(name)) continue;
    var rest = line.substring(name.length);
    if (rest.startsWith('{')) {
      final close = rest.indexOf('}');
      if (close < 0) return null;
      rest = rest.substring(close + 1);
    } else if (!rest.startsWith(' ')) {
      continue; // a longer metric name that merely starts the same way
    }
    return double.tryParse(rest.trim());
  }
  return null;
}

/// The part of the picture that only the running process knows.
class Scraped {
  const Scraped({this.pulls, this.failures, this.lastPullAge});

  factory Scraped.fromMetrics(String text) => Scraped(
    pulls: gauge(text, 'summareader_mcp_pulls_total'),
    failures: gauge(text, 'summareader_mcp_pull_failures_total'),
    lastPullAge: gauge(text, 'summareader_mcp_last_pull_age_seconds'),
  );

  final double? pulls;
  final double? failures;
  final double? lastPullAge;
}

/// The same numbers when the console did the pulling itself, so a pull started
/// here still shows while the server is down.
class OwnPulls {
  int pulls = 0;
  int failures = 0;
  DateTime? last;

  void pulled({required bool ok}) {
    pulls += 1;
    if (!ok) failures += 1;
    last = DateTime.now();
  }

  Scraped get scraped => Scraped(
    pulls: pulls.toDouble(),
    failures: failures.toDouble(),
    lastPullAge: last == null
        ? null
        : DateTime.now().difference(last!).inSeconds.toDouble(),
  );
}

/// How long ago, in the roughest terms that are still true.
///
/// Nobody reads a status pane for a figure in seconds, and a pull that
/// happened 4,812 seconds ago is a sentence the reader has to do arithmetic on
/// before it means anything.
String ago(double? seconds) {
  if (seconds == null) return 'never';
  if (seconds < 90) return 'just now';
  if (seconds < 3600) return _ago(seconds ~/ 60, 'minute');
  if (seconds < 172800) return _ago(seconds ~/ 3600, 'hour');
  return _ago(seconds ~/ 86400, 'day');
}

/// Two words of English rather than a pluralisation library, for the three
/// nouns this pane ever counts.
String _ago(int count, String noun) =>
    '$count $noun${count == 1 ? '' : 's'} ago';

/// The stats pane, as label-and-value pairs.
///
/// Pairs rather than a formatted block, so the same numbers can be laid out as
/// a grid and asserted in a test without parsing a paragraph back apart.
List<(String, String)> formatStats(
  Map<String, int> counts,
  String? cursor, [
  Scraped? scraped,
]) {
  final failures = scraped?.failures;
  return [
    ('Articles', '${counts['items'] ?? 0}'),
    ('Unread', '${counts['unread'] ?? 0}'),
    ('Summarized', '${counts['summarized'] ?? 0}'),
    ('With text', '${counts['bodies'] ?? 0}'),
    ('Sources', '${counts['sources'] ?? 0}'),
    ('Cursor', '${int.tryParse(cursor ?? '') ?? 0}'),
    ('Last pull', ago(scraped?.lastPullAge)),
    // Zero failures is worth printing rather than hiding: "0" is the
    // reassurance, and a blank reads as "not measured".
    ('Failures', failures == null ? '—' : '${failures.toInt()}'),
  ];
}

/// Why half the console is greyed out, in a sentence rather than by silence.
///
/// `--remote` is a reader with no library of its own. Searching one and
/// reading its counts is exactly what it is for; starting, stopping and
/// pulling are things only the machine holding the library can do, and this
/// process is not it. `--library` is the other half of the same shape: a file
/// the app owns, opened read-only, with no sync server behind it to pull from.
///
/// Said in a sentence for the same reason cli.py says it in a sentence when
/// `serve` is asked for over `--remote` — a greyed-out button explains
/// nothing, and the reader is left wondering what they broke.
String? refusal({String? remote, String? library, String? incomplete}) {
  if (remote != null && remote.isNotEmpty) {
    return 'Reading the mirror at $remote. Search and the counts are its '
        'answers; Start, Stop and Pull belong to the machine that holds the '
        'library, so they are off here.';
  }
  if (library != null && library.isNotEmpty) {
    return 'Reading $library directly, read-only. There is nothing to start '
        'and nothing to pull: the app owns this file and keeps it up to date '
        'itself.';
  }
  if (incomplete != null && incomplete.isNotEmpty) {
    return 'Not configured yet: $incomplete. Until that is filled in there is '
        'no mirror to start and nothing to pull from — the counts below are '
        'whatever the library on this machine already holds.';
  }
  return null;
}

String statusLine({
  required bool running,
  required String url,
  required bool managed,
}) => running
    ? 'Running on $url${managed ? ' (systemd)' : ''}'
    : 'Not running — $url';

/// The address to *ask*, which is not always the address bound.
///
/// 0.0.0.0 and :: are decisions about what to accept, not places to connect
/// to; asking them is a connection refused on some stacks and a surprise on
/// others.
String reachable(String host, int port) {
  var where = host;
  if (const ['0.0.0.0', '', '::', '*'].contains(where)) where = '127.0.0.1';
  if (where.contains(':') && !where.startsWith('[')) where = '[$where]';
  return 'http://$where:$port';
}

/// What closing the console has to ask before it does anything.
///
/// An interface for two questions so that the teardown rule can be tested
/// without a real server on the machine running the test: the rule is the
/// thing that was wrong an hour ago, and a rule nothing can ask about is a
/// rule that goes wrong again.
abstract interface class Owned {
  bool get managed;

  Future<void> stop();
}

/// The server, whoever happens to own it.
///
/// Holds a child process when it started one, and holds nothing at all when a
/// unit is installed — in which case every method here is a systemctl call.
class Supervisor implements Owned {
  Supervisor({
    required this.configFile,
    required this.cacheDir,
    required this.host,
    required this.port,
    this.bearerToken,
    http.Client? client,
    bool Function()? owner,
    Future<void> Function(List<String>)? manager,
  }) : _client = client ?? http.Client(),
       // Both default to the real thing and exist so a test can ask what this
       // does when a unit owns the server, on a machine where installing one
       // to find out would be an actual service on somebody's desktop.
       _owner = owner ?? serviceInstalled,
       _manager = manager ?? systemctl;

  final bool Function() _owner;
  final Future<void> Function(List<String>) _manager;

  final String configFile;
  final String cacheDir;
  final String? bearerToken;
  String host;
  int port;

  final http.Client _client;
  Process? _child;

  @override
  bool get managed => _owner();

  String get url => reachable(host, port);

  Future<bool> running() async {
    if (managed) {
      final done = await Process.run('systemctl', [
        '--user',
        'is-active',
        '--quiet',
        unitName,
      ]);
      return done.exitCode == 0;
    }
    return _child != null;
  }

  /// What the port says, which is the only answer that counts.
  ///
  /// A process that is up but has not bound yet, and one somebody else
  /// started, are both cases where "is there a child" is the wrong question.
  /// /health needs no credential on purpose.
  Future<bool> healthy() async => await _get('$url/health', null) != null;

  Future<void> start() async {
    final command = startCommand(managed: managed, host: host, port: port);
    if (managed) {
      // `systemctl --user` is the first two words of it; systemctl() puts them
      // back. Asked of startCommand either way, so the test that says a unit
      // is never bypassed is asking the code that runs.
      await _manager(command.sublist(2));
      return;
    }
    if (_child != null) return;
    // The config file and cache the console is reading are the ones the child
    // must read, or it mirrors into a different library than the one in the
    // search box below it.
    final child = await Process.start(
      command.first,
      command.sublist(1),
      environment: {
        'SUMMAREADER_MCP_CONFIG': configFile,
        'SUMMAREADER_MCP_CACHE': cacheDir,
      },
    );
    _child = child;
    // A server that dies on its own — a port already held, a key it cannot
    // read — leaves nothing behind to notice it by, and Start would then
    // refuse to try again because it believes a child is still there.
    unawaited(child.exitCode.then((_) => _child = null));
  }

  @override
  Future<void> stop() async {
    if (managed) {
      await _manager(['stop', unitName]);
      return;
    }
    final child = _child;
    if (child == null) return;
    _child = null;
    // Terminate first, so the server closes the library instead of being cut
    // off mid-write. A server that ignores it has to be killed anyway, so both
    // roads end at kill.
    child.kill(ProcessSignal.sigterm);
    await child.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        child.kill(ProcessSignal.sigkill);
        return child.exitCode;
      },
    );
  }

  /// Sync once, now, rather than waiting for the server's own timer.
  ///
  /// A subprocess rather than something done here: pulling means the master
  /// key, the envelope format and the whole sync protocol, and a second
  /// implementation of those in another language is the last thing this
  /// program should own. Every record applies by id and the library is in WAL,
  /// so a pull that overlaps the running server's own five-minute one costs a
  /// duplicate fetch and nothing worse.
  Future<String> pull() async {
    final exe = launcher();
    final done = await Process.run(
      exe.first,
      [...exe.sublist(1), 'pull'],
      environment: {
        'SUMMAREADER_MCP_CONFIG': configFile,
        'SUMMAREADER_MCP_CACHE': cacheDir,
      },
    );
    final said = '${done.stdout}\n${done.stderr}'
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    // The last line is the report `pull` prints; the ones before it are the
    // progress it printed on the way.
    if (done.exitCode != 0) {
      throw StateError(said.isEmpty ? 'pull failed' : said.last);
    }
    return said.isEmpty ? 'pulled' : said.last;
  }

  Future<Scraped?> scraped() async {
    final text = await _get('$url/metrics', bearerToken);
    return text == null ? null : Scraped.fromMetrics(text);
  }

  Future<String?> _get(String url, String? token) async {
    try {
      final response = await _client
          .get(
            Uri.parse(url),
            headers: token == null ? null : {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200 ? response.body : null;
    } catch (_) {
      // A server that is down is not an error to report; it is the thing the
      // status line is there to say, and this runs every two seconds.
      return null;
    }
  }

  void close() => _client.close();
}

/// What closing the console does to the server.
///
/// A child this console started dies with it: left running it holds the port
/// and the library with nothing on screen admitting to it, and the next
/// console's Start fails to bind — which reads from there as "Start did
/// nothing", the failure this file is most careful about elsewhere.
///
/// A server systemd owns is emphatically not ours to stop. Outliving the
/// console is the entire point of installing the unit.
Future<void> stopOnClose(Owned? supervisor) async {
  if (supervisor == null || supervisor.managed) return;
  await supervisor.stop();
}
