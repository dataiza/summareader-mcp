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

import 'src/addresses.dart';
import 'src/config.dart';
import 'src/desktop_entry.dart';
import 'src/file_choice.dart';
import 'src/first_run.dart';
import 'src/updates.dart';
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
      title: 'SummaReader MCP',
      debugShowCheckedModeBanner: false,
      theme: Ar.themeData(brightness),
      home: ConsoleScreen(options: options),
    );
  }
}

class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({
    super.key,
    required this.options,
    this.chooser = const PlatformDirectoryChooser(),
  });

  final Options options;

  /// The real dialog, unless something without a screen is handed one.
  final DirectoryChooser chooser;

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  // Not final: moving the library rewrites the file this was read from, and
  // everything below — which library is open, what the unit says, where the
  // server is told to look — has to follow it rather than describe the file
  // as it was when the window opened.
  MirrorConfig _config = _nothing;
  static final _nothing = MirrorConfig.forLibrary('');
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
  List<LanAddr> _lan = const [];
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
    _config = widget.options.configuration;
    _open();

    // After the first frame, because a dialog needs a Navigator and there is
    // none until this widget is in a tree. Only when nothing named a location:
    // a `cache_dir`, SUMMAREADER_MCP_CACHE or a library all mean the question
    // is already answered.
    if (!_config.saidWhere) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askWhereToPutIt());
    } else {
      // The two first-run questions are asked one at a time, and where is the
      // more important of them: somebody answering where the library goes
      // should not be handed a second dialog on top of the first.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _offerTheMenu();
        await _offerToRepoint();
      });
    }
    if (_local) {
      // Flag first, then whatever the config file and the environment say —
      // which is the whole point of writing the address back: this window
      // opens on the address it was last told to use.
      final supervisor = Supervisor(
        configFile: _config.file,
        cacheDir: _config.cacheDir,
        host: widget.options.host ?? _config.host,
        port: widget.options.port ?? _config.port,
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
      // An address that came out of the file gets the same refusal as one
      // chosen in the window — said now rather than at the first click, since
      // the file is where a wide bind with no token most easily hides.
      _message = _message.isEmpty
          ? (_refusal(supervisor.host) ?? '')
          : _message;
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
    // Cheap, and an interface that came up since the window opened is one
    // somebody may well be trying to bind to right now.
    final lan = supervisor == null ? const <LanAddr>[] : await lanAddrs();
    final cursor = await _quietly(() => library?.setting('sync.cursor'));
    final scraped = supervisor == null ? null : await supervisor.scraped();
    final healthy = supervisor == null ? false : await supervisor.healthy();
    if (!mounted) return;
    setState(() {
      _counts = counts ?? const {};
      _lan = lan;
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

  /// One button, so what it does depends on what is running.
  ///
  /// `_act` holds _busy for the length of this, which is the guard against the
  /// second click that lands while the first start is still in flight — two
  /// servers on one library, the second failing to bind.
  Future<void> _toggle() => _act(_running ? 'stopping' : 'starting', () async {
    final supervisor = _supervisor!;
    if (_running) {
      await supervisor.stop();
      return 'stopped';
    }
    // Before anything is started, not after: a server already listening on a
    // wide address with no token is the thing being prevented.
    final refused = _refusal(supervisor.host);
    if (refused != null) return refused;
    await supervisor.start();
    return 'started';
  });

  /// Why this address is refused, or null. See [bindRefusal]: this port serves
  /// the whole library in plaintext, so anything wider than loopback needs the
  /// bearer token that guards it.
  String? _refusal(String host) => bindRefusal(
    host,
    hasToken: _config.bearerToken != null,
    configFile: _config.file,
  );

  /// Rebinding is a restart, because a listening socket cannot be moved. The
  /// unit is rewritten too when there is one — otherwise the address changes
  /// in this window and comes back the old one at the next login, with nothing
  /// said.
  Future<void> _rebind(String host, int port) => _act('rebinding', () async {
    final supervisor = _supervisor!;
    if (host == supervisor.host && port == supervisor.port) return '';
    final refused = _refusal(host);
    if (refused != null) return refused;

    // Written before anything is stopped, and before the unit: a config file
    // that will not parse is a refusal, and refusing with the server still up
    // on its old address beats leaving it down. A unit and a config that
    // disagree is worse than either, so both or neither.
    _config.saveBind(host: host, port: port);

    final wasRunning = await supervisor.running();
    await supervisor.stop();
    supervisor.host = host;
    supervisor.port = port;
    if (serviceInstalled()) {
      await installService(
        renderUnit(
          host: host,
          port: port,
          configFile: _config.file,
          cacheDir: _config.cacheDir,
        ),
      );
    } else if (wasRunning) {
      await supervisor.start();
    }
    return 'listening on ${supervisor.url}';
  });

  /// A port that is not a port is a server that will not start, and the field
  /// is the only place to say so.
  void _setPort(String typed) {
    final port = int.tryParse(typed.trim());
    if (port == null || port < 1 || port > 65535) {
      _fading.say('$typed is not a port number.');
      return;
    }
    unawaited(_rebind(_supervisor!.host, port));
  }

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
        host: _supervisor?.host ?? widget.options.host ?? _config.host,
        port: _supervisor?.port ?? widget.options.port ?? _config.port,
        hosts: _supervisor == null
            ? const []
            : bindHosts(_supervisor!.host, _lan),
        configRows: _configRows(),
        libraryPath: _config.remote ?? _libraryPath,
        ownsLibrary: !_config.readsALocalLibrary,
        results: _results,
        local: _local,
        // Linux only, and absent rather than greyed out elsewhere: systemd is
        // what this switch writes, and a control that cannot work anywhere on
        // this machine is worse than no control at all.
        atLogin: _local && Platform.isLinux ? _atLogin : null,
        message: _message,
        busy: _busy,
        // Both controls exist only for an AppImage: it is the one form that is
        // a single file this program owns, so replacing it and registering it
        // are things it can honestly offer to do.
        updatable: runningImage() != null,
        inMenu: isInMenu(),
      ),
      query: _query,
      onToggle: _toggle,
      onPull: _pull,
      onSearch: _search,
      onAtLogin: _setAtLogin,
      onBind: (host) => unawaited(_rebind(host, _supervisor!.port)),
      onPort: _setPort,
      onLibrary: _local ? _setLibrary : null,
      onBrowse: _local ? _browse : null,
      // Only where there is a file to write into: `--remote` and `--library`
      // name none, and a console reading somebody else's mirror has no
      // business being handed a master key.
      onPair: _config.fromAFile ? _pair : null,
      onCheckUpdates: _checkUpdates,
      onInMenu: _setInMenu,
    );
  }

  /// What the field shows: the directory when this mirror owns the library,
  /// the file itself when it is reading somebody else's. Those are the two
  /// things the config actually holds, and showing one while writing the
  /// other is how a path stops round-tripping.
  String get _libraryPath =>
      _config.readsALocalLibrary ? _config.database : _config.cacheDir;

  /// Moves the library, or changes who owns it.
  ///
  /// Validated before anything is stopped, like a rebind and for the same
  /// reason: a typo should cost a sentence, not a server. The config is
  /// written first so a refusal leaves the running mirror on the library it
  /// already had, and the unit is rewritten when there is one, because it
  /// carries SUMMAREADER_MCP_CACHE and a unit that disagrees with the config
  /// brings the old library back at the next login.
  /// The first-run question, asked once and then never again.
  ///
  /// Writing the key is what makes it once — `saidWhere` is false only while
  /// nothing has. Dismissing without answering leaves the default and asks
  /// again, which is right: the question is "where", and no answer is not one.
  /// Asks GitHub whether there is a newer release, and takes it.
  ///
  /// Both halves report through [_act], so the toast says what is happening
  /// and what happened — a forty-megabyte download with no sign of life reads
  /// as a window that has hung.
  Future<void> _checkUpdates() => _act('checking', () async {
    final found = await const GitHubUpdates().newer();
    if (found == null) return 'This is the newest release.';

    final refusal = await replaceRunningImage(found);
    if (refusal != null) return refusal;
    return 'Updated to ${found.version}. Restart to use it.';
  });

  /// Puts the console in the applications menu, or takes it out.
  ///
  /// The answer is remembered either way, which is what makes the question on
  /// the first run a question asked once rather than every launch.
  Future<void> _setInMenu(bool wanted) =>
      _act(wanted ? 'adding to the menu' : 'removing from the menu', () async {
        final image = runningImage();
        if (image == null) return 'This is not running as an AppImage.';

        // Moved somewhere it can stay before the entry names it. The entry
        // holds an absolute path, and until this it named wherever the file
        // happened to be when the question was answered — usually a downloads
        // folder, which people empty.
        final kept = wanted ? await keepImage(image) : image;
        final refusal = wanted ? await addToMenu(kept) : await removeFromMenu();
        if (refusal != null) return refusal;

        _config.save({'in_menu': wanted});
        _config = widget.options.configuration;
        return wanted
            ? 'Added. It should appear in your applications shortly.'
            : 'Removed from the applications menu.';
      });

  /// Offers to repoint a menu entry that names somewhere else.
  ///
  /// Somebody moved the file by hand, or is running a second copy. The entry
  /// still names the old path, so the icon in their launcher starts nothing —
  /// and this is the only moment anything can notice, because the program that
  /// would have complained is the one that is not there.
  Future<void> _offerToRepoint() async {
    if (!mounted || !menuIsStale()) return;

    final image = runningImage();
    if (image == null) return;
    final wanted = await askAboutARepoint(context, menuTarget() ?? '', image);
    if (!mounted || !wanted) return;
    await _setInMenu(true);
  }

  /// Offers the menu once, on a first run that is an AppImage.
  ///
  /// Only when the key is absent: a `false` there is somebody having said no,
  /// and asking again would make "once" mean "every launch until you give in".
  Future<void> _offerTheMenu() async {
    if (!mounted || runningImage() == null) return;
    if (_config.inMenu != null || isInMenu()) return;

    final wanted = await askAboutTheMenu(context);
    if (!mounted) return;
    if (wanted) {
      await _setInMenu(true);
    } else {
      _config.save({'in_menu': false});
      _config = widget.options.configuration;
    }
  }

  Future<void> _askWhereToPutIt() async {
    if (!mounted) return;
    final wanted = await askWhereTheLibraryGoes(context, _config.cacheDir);
    if (wanted == null || !mounted) return;

    // Before anything is written, because the answer decides what is written.
    // Finding a library here is almost always what was meant, so this only
    // comes up when there is something to lose — and here that is time rather
    // than anything irreplaceable, since the mirror rebuilds from the log.
    if (holdsALibrary(wanted)) {
      await askAboutWhatIsAlreadyThere(context, wanted);
      if (!mounted) return;
    }

    // Through the same route the Configuration row uses, which already stops
    // the server, writes the key, rewrites the unit and reopens the library in
    // the right order — a unit that disagrees with the config brings the old
    // directory back at the next login.
    await _setLibrary(wanted, existing: false);
  }

  /// The same errand as typing a path, with the typing done by a dialog.
  ///
  /// A directory in both modes: the mirror's own copy is one, and an existing
  /// library is the app's file *inside* one — nobody navigates to an
  /// application support directory to pick a `.sqlite` out of it. What comes
  /// back goes through [_setLibrary] like anything typed, so `libraryRefusal`
  /// is still the only thing that decides whether a path will do.
  Future<void> _browse({required bool existing}) async {
    final chosen = await chooseLibrary(
      widget.chooser,
      existing: existing,
      startingIn: _config.readsALocalLibrary
          ? File(_config.database).parent.path
          : _config.cacheDir,
    );
    if (!mounted) return;
    if (chosen.refusal != null) {
      _fading.say(chosen.refusal!);
      return;
    }
    if (chosen.path != null) {
      await _setLibrary(chosen.path!, existing: existing);
    }
  }

  Future<void> _setLibrary(String path, {required bool existing}) =>
      _act('moving', () async {
        final trimmed = path.trim();
        if (trimmed == _libraryPath && existing == _config.readsALocalLibrary) {
          return '';
        }
        final refused = libraryRefusal(trimmed, existing: existing);
        if (refused != null) return refused;

        _config.saveLibrary(
          library: existing ? trimmed : null,
          cacheDir: existing ? null : trimmed,
        );
        await _reopen();
        return existing
            ? 'reading $trimmed, read-only'
            : 'its own library, in $trimmed';
      });

  /// Everything the config file decides, opened again after it changed.
  ///
  /// Shared by the library row and by pairing, because the order is the part
  /// that goes wrong: stop first, read the file back, then build a supervisor
  /// around what it now says — and rewrite the unit when there is one, since
  /// it carries SUMMAREADER_MCP_CACHE and a unit that disagrees with the
  /// config brings the old arrangement back at the next login.
  Future<void> _reopen() async {
    final previous = _supervisor;
    final wasRunning = await previous?.running() ?? false;
    await previous?.stop();
    _config = widget.options.configuration;
    _library?.close();
    _open();
    // Rebuilt rather than mutated: a supervisor holds the config file and the
    // cache directory it was handed, and those are what has just changed.
    // Built from nothing when pairing is what turned this console into the
    // machine that holds a library — until then there was no mirror to
    // supervise, and Start had nothing to call.
    if (previous != null || _local) {
      _supervisor = Supervisor(
        configFile: _config.file,
        cacheDir: _config.cacheDir,
        host: previous?.host ?? widget.options.host ?? _config.host,
        port: previous?.port ?? widget.options.port ?? _config.port,
        bearerToken: _config.bearerToken,
      );
      previous?.close();
    }
    unawaited(_search(_query.text));
    if (serviceInstalled()) {
      await installService(
        renderUnit(
          host: _config.host,
          port: _config.port,
          configFile: _config.file,
          cacheDir: _config.cacheDir,
        ),
      );
    } else if (wasRunning) {
      await _supervisor?.start();
    }
  }

  /// The whole of a configuration, in one paste.
  ///
  /// The three values a mirror needs were hand-edited in, which is a base64
  /// key retyped across a desk; the app already puts exactly them on the
  /// clipboard. Written in one save, because a file holding a new server
  /// beside an old token is a mirror that pulls nothing and says nothing
  /// about why. The key goes in and is never read back out: the message this
  /// returns names the server and nothing else.
  Future<void> _pair(String pasted) => _act('pairing', () async {
    final pairing = Pairing.read(pasted);
    if (pairing.refusal != null) return pairing.refusal!;
    _config.save(pairing.keys!);
    await _reopen();
    return 'paired with ${_config.server}';
  });

  List<(String, String)> _configRows() => [
    ('File', _config.file),
    ('Sync server', _config.server ?? '—'),
    ('Name', _config.instanceName ?? '(unset)'),
    // Whether there is one, and never what it is. Pairing writes this key and
    // nothing reads it back out — a window that can show a master key is a
    // window that can lose one to a screenshot.
    ('Master key', _config.masterKey == null ? 'not set' : 'set'),
    // Never the token itself. A window that shows a credential is a window
    // somebody screenshots.
    (
      'Bearer token',
      _config.bearerToken == null ? 'not set — the port is open' : 'set',
    ),
  ];
}
