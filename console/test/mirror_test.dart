/// The console, without a display.
///
/// Everything here is a question that goes wrong silently: the argv a unit
/// runs, who owns the server, what closing the window does to it, and which
/// numbers reach the pane. A wrong ExecStart is a service that fails at the
/// next login in a log nobody has open, so it is asserted against the bytes
/// rather than by installing one and hoping.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:summareader_mcp_console/src/addresses.dart';
import 'package:summareader_mcp_console/src/file_choice.dart';
import 'package:summareader_mcp_console/src/mirror.dart';

const exe = ['/home/you/.local/bin/summareader-mcp'];

void main() {
  group('which library, and whose', () {
    test('an existing library has to exist', () {
      final missing = '${Directory.systemTemp.path}/nothing-here.sqlite';
      expect(libraryRefusal(missing, existing: true), contains('Nothing at'));
    });

    test('and is accepted when it does', () {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/library.sqlite')..writeAsStringSync('');

      expect(libraryRefusal(file.path, existing: true), isNull);
    });

    test('its own copy refuses a directory that already holds one', () {
      // Otherwise "its own copy" quietly adopts a library something else is
      // filling, and two cursors start fighting over one file.
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/library.sqlite').writeAsStringSync('');

      expect(libraryRefusal(dir.path, existing: false), contains('already'));
    });

    test('its own copy accepts an empty directory', () {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(libraryRefusal(dir.path, existing: false), isNull);
    });

    test('and one not made yet, beside one that is', () {
      // Making a directory is reasonable; making a path somebody mistyped
      // four levels deep is how a library ends up somewhere nobody looks
      // for it again.
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(libraryRefusal('${dir.path}/mirror', existing: false), isNull);
      expect(
        libraryRefusal('${dir.path}/a/b/c/mirror', existing: false),
        contains('to put it in'),
      );
    });

    test('an empty path changes nothing, in either direction', () {
      expect(libraryRefusal('  ', existing: true), contains('path is needed'));
      expect(libraryRefusal('', existing: false), contains('path is needed'));
    });
  });

  test('the unit runs what Start runs', () {
    // The whole reason the server is a child process rather than something
    // embedded here. A unit whose ExecStart has drifted from what the console
    // starts is two different servers wearing one name.
    final unit = renderUnit(
      host: '127.0.0.1',
      port: 8100,
      configFile: '/home/you/.config/summareader-mcp/summareader-mcp.json',
      cacheDir: '/home/you/.cache/summareader-mcp',
      exe: exe,
    );
    final argv = serveArgv('127.0.0.1', 8100, exe: exe).join(' ');

    expect(unit, contains('ExecStart=$argv\n'));
    expect(argv, contains('--transport=http'));
    for (final wanted in [
      'Environment="SUMMAREADER_MCP_CONFIG='
          '/home/you/.config/summareader-mcp/summareader-mcp.json"',
      'Environment="SUMMAREADER_MCP_CACHE=/home/you/.cache/summareader-mcp"',
      'ReadWritePaths=/home/you/.cache/summareader-mcp',
      'NoNewPrivileges=true',
      'ProtectSystem=strict',
      'WantedBy=default.target',
    ]) {
      expect(unit, contains(wanted));
    }

    // And what the console reads back on the next launch, so it reopens on
    // the server that is running rather than on its own defaults.
    expect(unitBind(unit), ('127.0.0.1', 8100));
    expect(unitBind('[Service]\nExecStart=summareader-mcp serve\n'), isNull);
  });

  test('a unit owns the server and the console only asks it', () {
    // One owner at a time. With a unit installed, a console that started a
    // child of its own would put a second server on one library: both
    // pulling, both advancing the same cursor, and the second failing to
    // bind — which from here reads as "Start did nothing".
    final managed = startCommand(
      managed: true,
      host: '127.0.0.1',
      port: 8100,
      exe: exe,
    );
    expect(managed, [
      'systemctl',
      '--user',
      'start',
      'summareader-mcp.service',
    ]);
    expect(managed, isNot(contains(exe.first)));

    expect(
      startCommand(managed: false, host: '127.0.0.1', port: 8100, exe: exe),
      serveArgv('127.0.0.1', 8100, exe: exe),
    );
  });

  test(
    'the supervisor never spawns a child when a unit owns the server',
    () async {
      // The same rule as startCommand, asserted at the seam that could break
      // it: nothing else can tell the difference until the library is already
      // being written by two processes.
      final asked = <List<String>>[];
      final supervisor = Supervisor(
        configFile: '/tmp/c.json',
        cacheDir: '/tmp',
        host: '127.0.0.1',
        port: 8100,
        owner: () => true,
        manager: (args) async => asked.add(args),
      );

      await supervisor.start();
      await supervisor.stop();
      expect(asked, [
        ['start', 'summareader-mcp.service'],
        ['stop', 'summareader-mcp.service'],
      ]);
      supervisor.close();
    },
  );

  group('closing the console', () {
    test('a child started here dies here', () async {
      // Otherwise it holds the port and the library after the window is gone,
      // and the next Start fails to bind.
      final child = _Fake(managed: false);
      await stopOnClose(child);
      expect(child.stopped, isTrue);
    });

    test('a service is left alone', () async {
      // Outliving the window is the whole reason somebody installed a unit.
      final service = _Fake(managed: true);
      await stopOnClose(service);
      expect(service.stopped, isFalse);
    });

    test('a console with nothing to supervise closes quietly', () async {
      // --remote and --library never build one.
      await stopOnClose(null);
    });
  });

  test('the unit is looked for where systemd looks', () {
    expect(
      unitPath({'XDG_CONFIG_HOME': '/tmp/xdg'}),
      '/tmp/xdg/systemd/user/summareader-mcp.service',
    );
    expect(
      unitPath({'HOME': '/home/you'}),
      '/home/you/.config/systemd/user/summareader-mcp.service',
    );
    expect(serviceInstalled({'XDG_CONFIG_HOME': '/tmp/nothing-here'}), isFalse);
  });

  test('the scraper reads a named mirror\'s metrics too', () {
    // Every sample is labelled as soon as a name is configured, so a parser
    // matching only a bare name would read every number as missing on exactly
    // the installations that bothered to name themselves — and a pane showing
    // "0 pulls" for ever looks like a server that has never synced.
    const text =
        '# TYPE summareader_mcp_pulls_total counter\n'
        'summareader_mcp_pulls_total{instance="MCP mirror"} 14\n'
        'summareader_mcp_pull_failures_total{instance="MCP mirror"} 2\n'
        'summareader_mcp_last_pull_age_seconds{instance="MCP mirror"} 240\n';
    final scraped = Scraped.fromMetrics(text);
    expect(scraped.pulls, 14);
    expect(scraped.failures, 2);
    expect(scraped.lastPullAge, 240);

    expect(
      gauge('summareader_mcp_pulls_total 3\n', 'summareader_mcp_pulls_total'),
      3,
    );
    // A longer name that merely starts the same way is a different metric,
    // and reading it as this one is a wrong number rather than a missing one.
    expect(
      gauge('summareader_mcp_items_summarized 7\n', 'summareader_mcp_items'),
      isNull,
    );
    expect(gauge('', 'summareader_mcp_items'), isNull);
  });

  test('the pane shows what the library holds and how the syncing went', () {
    final shown = Map.fromEntries(
      formatStats(
        const {
          'items': 1284,
          'unread': 37,
          'summarized': 1190,
          'bodies': 1102,
          'sources': 9,
        },
        '418',
        const Scraped(failures: 0, lastPullAge: 90),
      ).map((pair) => MapEntry(pair.$1, pair.$2)),
    );

    expect(shown['Articles'], '1284');
    expect(shown['Unread'], '37');
    expect(shown['Summarized'], '1190');
    expect(shown['With text'], '1102');
    expect(shown['Sources'], '9');
    expect(shown['Cursor'], '418');
    expect(shown['Last pull'], '1 minute ago');
    // Zero failures is worth printing: "0" is the reassurance, and a dash
    // reads as "not measured".
    expect(shown['Failures'], '0');

    final quiet = Map.fromEntries(
      formatStats(const {}, null).map((p) => MapEntry(p.$1, p.$2)),
    );
    expect(quiet['Articles'], '0');
    expect(quiet['Last pull'], 'never');
    expect(quiet['Failures'], '—');
  });

  test('how long ago, in the roughest terms that are still true', () {
    expect(ago(null), 'never');
    expect(ago(12), 'just now');
    expect(ago(3599), '59 minutes ago');
    expect(ago(3600), '1 hour ago');
    expect(ago(172800), '2 days ago');
  });

  test('the status line says who is running it', () {
    expect(
      statusLine(running: true, url: 'http://127.0.0.1:8100', managed: true),
      'Running on http://127.0.0.1:8100 (systemd)',
    );
    expect(
      statusLine(running: true, url: 'http://127.0.0.1:8100', managed: false),
      'Running on http://127.0.0.1:8100',
    );
    expect(
      statusLine(running: false, url: 'http://127.0.0.1:8100', managed: false),
      startsWith('Not running'),
    );
  });

  test('the console asks an address it can actually reach', () {
    // 0.0.0.0 is a decision about what to accept, not a place to connect to:
    // a server bound there is up and answering, and a console polling
    // http://0.0.0.0:8100 shows it as down on some stacks and hangs on others.
    expect(reachable('0.0.0.0', 8100), 'http://127.0.0.1:8100');
    expect(reachable('::', 8100), 'http://127.0.0.1:8100');
    expect(reachable('192.168.1.24', 8100), 'http://192.168.1.24:8100');
    expect(reachable('::1', 8100), 'http://[::1]:8100');
  });

  // A desktop with Docker or a VM manager on it holds several private
  // addresses and only some of them lead anywhere. Ordered against a
  // written-down list rather than against whatever this machine happens to
  // have plugged in, which is a different list on every machine.
  test('the virtual interfaces are offered last', () {
    final ordered = orderLanAddrs(const [
      LanAddr('172.18.0.1', 'br-27ee9d724738'),
      LanAddr('172.17.0.1', 'docker0'),
      LanAddr('10.10.20.1', 'enp7s0'),
      LanAddr('192.168.122.1', 'virbr0'),
      LanAddr('192.168.1.24', 'wlan0'),
      LanAddr('172.20.0.2', 'veth7f21a3c'),
    ]);

    expect(ordered.map((a) => a.iface), [
      'enp7s0',
      'wlan0',
      'br-27ee9d724738',
      'docker0',
      'virbr0',
      'veth7f21a3c',
    ]);

    // The address is what gets bound; the interface is only how the person
    // reading the chooser tells one 172.x from another.
    expect(ordered.first.toString(), '10.10.20.1 (enp7s0)');
    expect(const LanAddr('0.0.0.0').toString(), '0.0.0.0');
    expect(privateV4(InternetAddress('172.31.255.1')), isTrue);
    expect(privateV4(InternetAddress('172.32.0.1')), isFalse);
  });

  // Loopback and everything are decisions rather than addresses, so they are
  // offered even though no interface answers to them — and an address already
  // in use survives the list not containing it.
  test('the chooser offers both decisions first', () {
    const lan = [LanAddr('192.168.1.24', 'wlan0')];

    expect(bindHosts('127.0.0.1', lan).map((h) => h.ip), [
      '127.0.0.1',
      '0.0.0.0',
      '192.168.1.24',
    ]);
    // A hostname, or an address on an interface that is down: kept, rather
    // than silently rebinding a running server to something else.
    expect(bindHosts('mirror.local', lan).first.ip, 'mirror.local');
    expect(bindHosts('mirror.local', lan).length, 4);
  });

  // The one rule in this console that is not in the sync server's: this port
  // answers with the whole library in plaintext, and the only credential is
  // the bearer token. scripts/install.sh refuses the same choice.
  test('a wider bind is refused until there is a bearer token', () {
    final refused = bindRefusal(
      '0.0.0.0',
      hasToken: false,
      configFile: '/home/you/.config/summareader-mcp/summareader-mcp.json',
    );
    expect(refused, contains('plaintext'));
    // What to do about it, not merely that it is refused.
    expect(refused, contains('openssl rand -base64 32'));
    expect(refused, contains('summareader-mcp.json'));

    expect(bindRefusal('192.168.1.24', hasToken: false), isNotNull);
    expect(bindRefusal('0.0.0.0', hasToken: true), isNull);

    // One machine talking to itself is its own business, token or not.
    for (final host in ['127.0.0.1', '::1', 'localhost']) {
      expect(bindRefusal(host, hasToken: false), isNull);
      expect(bindRefusal(host, hasToken: true), isNull);
    }
  });

  // Changing the address in the window has to reach the unit, or the mirror
  // comes back on the old address at the next login with nothing said.
  test('a rebind rewrites an installed unit', () async {
    final temporary = Directory.systemTemp.createTempSync('unit');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final environment = {'XDG_CONFIG_HOME': temporary.path};
    final asked = <List<String>>[];

    String unitFor(String host, int port) => renderUnit(
      host: host,
      port: port,
      configFile: '/home/you/.config/summareader-mcp/summareader-mcp.json',
      cacheDir: '/home/you/.cache/summareader-mcp',
      exe: exe,
    );

    await installService(
      unitFor('127.0.0.1', 8100),
      environment: environment,
      manager: (args) async => asked.add(args),
    );
    expect(serviceInstalled(environment), isTrue);

    await installService(
      unitFor('0.0.0.0', 8200),
      environment: environment,
      manager: (args) async => asked.add(args),
    );

    // Written over rather than left beside: the address on disk is the one
    // that was chosen, and the console reads it back on the next launch.
    final written = File(unitPath(environment)).readAsStringSync();
    expect(unitBind(written), ('0.0.0.0', 8200));
    expect(written, isNot(contains('8100')));
    // And systemd is told, or it keeps running the unit it already parsed.
    expect(asked.where((a) => a.first == 'daemon-reload'), hasLength(2));
  });

  test('the mirror is found by the environment before anything else', () {
    expect(
      launcher(environment: {'SUMMAREADER_MCP_EXE': '/opt/summareader-mcp'}),
      ['/opt/summareader-mcp'],
    );
    // Nothing beside the console and nothing named: the bare name, resolved
    // on PATH, which is what a checkout with the package installed has.
    expect(launcher(environment: const {}, besideMe: null), isNotEmpty);
  });

  test('a mirror it does not hold says so in a sentence', () {
    // A greyed-out button explains nothing, and the reader is left wondering
    // what they broke.
    final remote = refusal(remote: 'http://mirror.local:8100');
    expect(remote, contains('http://mirror.local:8100'));
    expect(remote, contains('Start, Stop and Pull'));

    expect(refusal(library: '/home/you/library.sqlite'), contains('read-only'));
    expect(refusal(incomplete: 'the master key'), contains('the master key'));
    expect(refusal(), isNull);
    // --remote wins over the others: it is the mode the console is in, and
    // the sentence has to be about that one.
    expect(
      refusal(remote: 'http://x', incomplete: 'the master key'),
      contains('http://x'),
    );
  });

  /// Browse…, which is typing a path with a dialog doing the typing.
  ///
  /// The dialog itself is native and cannot be opened or dismissed from here,
  /// so it is the only part behind the seam; what a picked directory becomes,
  /// and what a dismissed one does not become, is ordinary code and is where
  /// this goes wrong.
  group('picking a directory', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('mcp-browse'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('its own copy takes the directory as it was picked', () async {
      final chosen = await chooseLibrary(_Picks(dir.path), existing: false);
      expect(chosen.path, dir.path);
      expect(chosen.refusal, isNull);
    });

    test('an existing library is the file inside the directory', () async {
      // Nobody navigates to an application support directory to pick a
      // .sqlite out of it, which is the whole reason this button exists.
      File('${dir.path}/summareader.sqlite').writeAsStringSync('');
      final chosen = await chooseLibrary(_Picks(dir.path), existing: true);
      expect(chosen.path, '${dir.path}/summareader.sqlite');
      expect(chosen.refusal, isNull);
    });

    test('the name it had before a rename is found too', () async {
      // Installs that predate it still hold one, and a console that looked
      // for one name would report a library sitting right there as missing.
      File('${dir.path}/allreader.sqlite').writeAsStringSync('');
      final chosen = await chooseLibrary(_Picks(dir.path), existing: true);
      expect(chosen.path, '${dir.path}/allreader.sqlite');
    });

    test('the current name wins where both are there', () async {
      for (final name in const ['summareader.sqlite', 'allreader.sqlite']) {
        File('${dir.path}/$name').writeAsStringSync('');
      }
      final chosen = await chooseLibrary(_Picks(dir.path), existing: true);
      expect(chosen.path, '${dir.path}/summareader.sqlite');
    });

    test('a directory holding neither is a sentence naming both', () async {
      final chosen = await chooseLibrary(_Picks(dir.path), existing: true);
      expect(chosen.path, isNull);
      expect(chosen.refusal, contains('summareader.sqlite'));
      expect(chosen.refusal, contains('allreader.sqlite'));
      expect(chosen.refusal, contains(dir.path));
    });

    test('a dialog somebody closed changes nothing', () async {
      for (final existing in const [true, false]) {
        final chosen = await chooseLibrary(_Picks(null), existing: existing);
        expect(chosen.path, isNull);
        expect(chosen.refusal, isNull);
      }
    });
  });
}

class _Fake implements Owned {
  _Fake({required this.managed});

  @override
  final bool managed;

  bool stopped = false;

  @override
  Future<void> stop() async => stopped = true;
}

/// A dialog that answers the same thing every time, and never draws anything.
class _Picks implements DirectoryChooser {
  const _Picks(this.answer);

  /// Null is somebody closing the dialog, which has to change nothing.
  final String? answer;

  @override
  Future<String?> chooseDirectory({String? startingIn}) async => answer;
}
