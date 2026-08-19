/// The mirror in a window, for the machine that holds the library.
///
/// The fourth way in, after the MCP server, the terminal interface and the
/// command line. It exists for the two steps that were terminal-only and had
/// no business being so: keeping the thing running, and searching what it
/// holds.
///
/// # Flutter, and not the toolkit that was here an hour ago
///
/// The window this replaces was Tkinter, chosen because it is in the standard
/// library and cost the frozen bundle nothing. What it also cost was looking
/// like nothing else the project ships: SummaReader is a Flutter app with a
/// palette, a type scale and a set of widgets, and a console in Tk's 1990s
/// defaults reads as a different program by a different author. The look now
/// lives in a package, so the console can simply use it — see
/// packages/summareader_ui, and the note in it about why it is a copy.
///
/// # The server is a child, not this process
///
/// `serve` blocks, holds the master key and is restarted by the person at the
/// keyboard. It is also Python, and this console is not — so it could hardly
/// be anything but a separate process. It is started with exactly the argv the
/// unit's ExecStart holds, which is asserted in the tests, because a desktop
/// path and a systemd path that spell the same command differently drift until
/// one of them is wrong at the next login, in a log nobody has open.
///
/// # One owner at a time
///
/// With a user unit installed, that unit owns the server and this console is a
/// remote control for it: Start and Stop drive `systemctl --user`, and the
/// console never starts a child of its own. Two servers on one library would
/// both pull, both advance the same cursor and both want the port — and the
/// second simply fails to bind, which reads from here as "Start did nothing".
///
/// # Where the numbers come from
///
/// Counts come out of the library file, which this console already has open
/// for the search box. What is *not* in the file is how the running process is
/// getting on — pulls, failures, how long since the last one — because that
/// lives in its memory. So that half is scraped from /metrics with the
/// configured bearer token, and /health is what "is it up" means.
library;

import 'dart:async';
import 'dart:io';
// AppExitResponse lives here rather than in the widgets layer.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:summareader_ui/summareader_ui.dart';

import 'src/config.dart';
import 'src/console.dart';
import 'src/library.dart';
import 'src/mirror.dart';

Future<void> main(List<String> argv) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ConsoleApp(options: Options.parse(argv)));
}

class ConsoleApp extends StatelessWidget {
  const ConsoleApp({super.key, required this.options});

  final Options options;

  @override
  Widget build(BuildContext context) {
    // One theme built, not two: `Ar` keeps its palette in a module-level value
    // that `themeData` sets, so handing MaterialApp a light and a dark one
    // would leave every widget drawing in whichever was constructed last.
    final brightness = MediaQuery.platformBrightnessOf(context);
    return MaterialApp(
      title: 'SummaReader mirror',
      debugShowCheckedModeBanner: false,
      theme: Ar.themeData(brightness),
      home: ConsoleScreen(options: options),
    );
  }
}

class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.options});

  final Options options;

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  late final MirrorConfig _config = widget.options.configuration;
  late final Fading _fading = Fading(
    (message) => setState(() => _message = message),
  );

  LibrarySource? _library;
  Supervisor? _supervisor;
  AppLifecycleListener? _lifecycle;
  Timer? _poll;

  final _query = TextEditingController();
  final _ownPulls = OwnPulls();

  List<Item> _results = const [];
  Map<String, int> _counts = const {};
  String? _cursor;
  Scraped? _scraped;
  bool _running = false;
  bool _managed = false;
  bool _atLogin = false;
  bool _busy = false;
  String _message = '';

  /// Whether this console is the machine that holds the library, which is the
  /// only place Start, Stop and Pull mean anything.
  bool get _local =>
      _config.remote == null &&
      !_config.readsALocalLibrary &&
      _config.missing == null;

  @override
  void initState() {
    super.initState();
    _open();
    if (_local) {
      final supervisor = Supervisor(
        configFile: _config.file,
        cacheDir: _config.cacheDir,
        host: widget.options.host,
        port: widget.options.port,
        bearerToken: _config.bearerToken,
      );
      // A unit already on disk knows where the server is; this console's own
      // defaults do not, and opening on them shows a running server as down.
      if (supervisor.managed) {
        final installed = unitBind(File(unitPath()).readAsStringSync());
        if (installed != null) {
          supervisor.host = installed.$1;
          supervisor.port = installed.$2;
        }
      }
      _supervisor = supervisor;
      _atLogin = serviceInstalled();
      // The one hook that closes the loop the review opened an hour ago: a
      // child started here dies here, and a server systemd owns is left alone.
      _lifecycle = AppLifecycleListener(
        onExitRequested: () async {
          await stopOnClose(_supervisor);
          return AppExitResponse.exit;
        },
      );
    }
    unawaited(_search(''));
    _tick();
    _poll = Timer.periodic(pollInterval, (_) => _tick());
  }

  void _open() {
    try {
      _library = _config.remote != null
          ? RemoteLibrary(_config.remote!, token: _config.bearerToken)
          : LocalLibrary.open(
              _config.database,
              readOnly: _config.readsALocalLibrary,
            );
    } catch (error) {
      // A library that will not open is a sentence, not a crash: on a mirror
      // that has never pulled there is simply no file yet, and the rest of
      // this window — the configuration, Start — is exactly what the person
      // came here to use.
      _library = null;
      _message = 'Cannot read ${_config.database}: $error';
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _fading.cancel();
    _lifecycle?.dispose();
    _query.dispose();
    _library?.close();
    _supervisor?.close();
    super.dispose();
  }

  // ---- the status pane -------------------------------------------------

  Future<void> _tick() async {
    final library = _library;
    final supervisor = _supervisor;
    final counts = await _quietly(() => library?.counts());
    final cursor = await _quietly(() => library?.setting('sync.cursor'));
    final scraped = supervisor == null ? null : await supervisor.scraped();
    final healthy = supervisor == null ? false : await supervisor.healthy();
    if (!mounted) return;
    setState(() {
      _counts = counts ?? const {};
      _cursor = cursor;
      // The server's own numbers while it is up, ours while it is not, so a
      // pull done from this window still shows.
      _scraped = supervisor == null ? null : (scraped ?? _ownPulls.scraped);
      _running = healthy;
      _managed = supervisor?.managed ?? false;
      if (supervisor != null) _atLogin = serviceInstalled();
    });
  }

  /// A question the library cannot answer right now is not worth a message
  /// every two seconds; the pane simply keeps the numbers it had.
  Future<T?> _quietly<T>(FutureOr<T?> Function() ask) async {
    try {
      return await ask();
    } catch (_) {
      return null;
    }
  }

  // ---- the buttons -----------------------------------------------------

  Future<void> _act(String doing, Future<String> Function() work) async {
    setState(() => _busy = true);
    _fading.say('$doing…');
    try {
      final said = await work();
      if (mounted) _fading.say(said);
    } catch (error) {
      if (mounted) _fading.say('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _tick();
    }
  }

  Future<void> _start() => _act('starting', () async {
    await _supervisor!.start();
    return 'started';
  });

  Future<void> _stop() => _act('stopping', () async {
    await _supervisor!.stop();
    return 'stopped';
  });

  Future<void> _pull() => _act('pulling', () async {
    try {
      final said = await _supervisor!.pull();
      _ownPulls.pulled(ok: true);
      return said;
    } catch (_) {
      _ownPulls.pulled(ok: false);
      rethrow;
    } finally {
      await _search(_query.text);
    }
  });

  Future<void> _setAtLogin(bool wanted) => _act(
    wanted ? 'installing the service' : 'removing the service',
    () async {
      final supervisor = _supervisor!;
      if (wanted) {
        await installService(
          renderUnit(
            host: supervisor.host,
            port: supervisor.port,
            configFile: _config.file,
            cacheDir: _config.cacheDir,
          ),
        );
      } else {
        await uninstallService();
      }
      // Read back from disk rather than from what was clicked: a switch turned
      // on next to a service that was never installed is the one wrong thing
      // this control can say.
      if (mounted) setState(() => _atLogin = serviceInstalled());
      return wanted ? 'installed as a user service' : 'service removed';
    },
  );

  Future<void> _search(String query) async {
    final library = _library;
    if (library == null) return;
    try {
      final found = await library.search(query, limit: 200);
      if (!mounted) return;
      setState(() => _results = found);
    } catch (error) {
      if (mounted) _fading.say('$error');
    }
  }

  // ---- what it all looks like ------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ConsoleView(
      state: ConsoleState(
        status: statusLine(
          running: _running,
          url: _supervisor?.url ?? _config.remote ?? _config.database,
          managed: _managed,
        ),
        running: _running,
        note: refusal(
          remote: _config.remote,
          library: _config.library,
          incomplete: _config.missing,
        ),
        stats: formatStats(_counts, _cursor, _scraped),
        configRows: _configRows(),
        results: _results,
        local: _local,
        // Linux only, and absent rather than greyed out elsewhere: systemd is
        // what this switch writes, and a control that cannot work anywhere on
        // this machine is worse than no control at all.
        atLogin: _local && Platform.isLinux ? _atLogin : null,
        message: _message,
        busy: _busy,
      ),
      query: _query,
      onStart: _start,
      onStop: _stop,
      onPull: _pull,
      onSearch: _search,
      onAtLogin: _setAtLogin,
    );
  }

  List<(String, String)> _configRows() => [
    ('File', _config.file),
    ('Library', _config.remote ?? _config.database),
    ('Sync server', _config.server ?? '—'),
    ('Name', _config.instanceName ?? '(unset)'),
    // Never the token itself. A window that shows a credential is a window
    // somebody screenshots.
    (
      'Bearer token',
      _config.bearerToken == null ? 'not set — the port is open' : 'set',
    ),
  ];
}
