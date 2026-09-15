/// Where this mirror reads from, and what it calls itself.
///
/// The same file `config.py` reads, read the same way — JSON first,
/// environment second — because the console and the mirror have to agree on
/// which library is being talked about. Read for everything, written for two
/// things only: the address and the port the window's Address chooser edits.
/// A choice made in a window that comes back the old one at the next login is
/// not a choice. Everything else stays read-only, the master key most of all:
/// a window that edits somebody's master key is a window that can lose it.
///
/// What is *not* here is the master key itself, the device token's use, or any
/// of the crypto. The console never decrypts anything; it starts the process
/// that does.
library;

import 'dart:convert';
import 'dart:io';

const _name = 'summareader-mcp';

class MirrorConfig {
  const MirrorConfig({
    required this.file,
    required this.cacheDir,
    this.saidWhere = true,
    this.server,
    this.token,
    this.masterKey,
    this.instanceName,
    this.bearerToken,
    this.library,
    this.remote,
    this.host = '127.0.0.1',
    this.port = 8100,
    this.fromAFile = true,
  });

  /// The config file, whether or not it exists — knowing which file to edit is
  /// most of the job of showing it.
  final String file;
  final String cacheDir;
  final String? server;
  final String? token;

  /// Held only to know whether it is there. Its value never leaves this
  /// object.
  final String? masterKey;
  final String? instanceName;
  final String? bearerToken;
  final String? library;
  final String? remote;

  /// What the http transport binds. The same defaults `config.py` holds, so a
  /// console opened before anything was configured opens on the address the
  /// server would have used anyway.
  final String host;
  final int port;

  /// False for the two arrangements below, which hold a sentence in [file]
  /// rather than a path. Asked before anything is written: `--remote` and
  /// `--library` name no config file, and pairing one of them would write a
  /// master key into a file called "(none — reading …)".
  final bool fromAFile;

  String get database => library ?? '$cacheDir/library.sqlite';

  bool get readsALocalLibrary => library != null;

  /// False when nothing named a location — no `cache_dir`, no
  /// SUMMAREADER_MCP_CACHE, no library. The one condition the window asks its
  /// first-run question on; writing the key is what stops it asking again.
  final bool saidWhere;

  /// A mirror pulls; these three are what it pulls with. Named rather than
  /// counted, so the sentence the console shows says which one is missing.
  String? get missing {
    if (remote != null || library != null) return null;
    final absent = [
      if (server == null || server!.isEmpty) 'the sync server',
      if (token == null || token!.isEmpty) 'the device token',
      if (masterKey == null || masterKey!.isEmpty) 'the master key',
    ];
    if (absent.isEmpty) return null;
    return absent.join(', ');
  }

  /// A reader over the port, with no library of its own.
  factory MirrorConfig.forRemote(String url, {String? token}) => MirrorConfig(
    file: '(none — reading $url)',
    cacheDir: '',
    fromAFile: false,
    remote: url,
    bearerToken: token,
  );

  /// A library file that is already here: no server, no keys, no second copy.
  factory MirrorConfig.forLibrary(String path) => MirrorConfig(
    file: '(none — reading $path)',
    cacheDir: File(path).parent.path,
    library: path,
    fromAFile: false,
  );

  static MirrorConfig load({String? file, Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final path =
        file ??
        _first(env, ['SUMMAREADER_MCP_CONFIG', 'ALLREADER_MCP_CONFIG']) ??
        defaultConfigPath(env);

    var stored = const <String, dynamic>{};
    final handle = File(path);
    if (handle.existsSync()) {
      try {
        final decoded = jsonDecode(handle.readAsStringSync());
        if (decoded is Map<String, dynamic>) stored = decoded;
      } on FormatException {
        // A file that will not parse is shown as the file it is, with nothing
        // read out of it. Refusing to open at all would leave somebody with a
        // typo and no window to find out where the file even lives.
        stored = const {};
      }
    }

    String? pick(String key, String envKey) {
      final fromEnv = _first(env, [
        envKey,
        envKey.replaceFirst('SUMMAREADER', 'ALLREADER'),
      ]);
      if (fromEnv != null) return fromEnv;
      final value = stored[key];
      // A JSON file spells a port as a number, not as a string, and reading
      // only strings would leave the file's port silently unread.
      if (value is num || value is bool) return '$value';
      return value is String && value.isNotEmpty ? value : null;
    }

    final said = pick('cache_dir', 'SUMMAREADER_MCP_CACHE');
    return MirrorConfig(
      file: path,
      cacheDir: said ?? defaultCacheDir(env),
      // Nothing said where, so nobody has been asked. Reading a `library` key
      // counts too — that is the other way to name a file, and somebody who
      // has named one has answered the question.
      saidWhere:
          said != null || pick('library', 'SUMMAREADER_MCP_LIBRARY') != null,
      server: pick('server', 'SUMMAREADER_SYNC_URL'),
      token: pick('token', 'SUMMAREADER_DEVICE_TOKEN'),
      masterKey: pick('master_key', 'SUMMAREADER_MASTER_KEY'),
      instanceName: pick('name', 'SUMMAREADER_MCP_NAME'),
      // The file's spelling of --library, read here as well so the console and
      // the mirror cannot disagree about which library is being talked about.
      library: pick('library', 'SUMMAREADER_MCP_LIBRARY'),
      // `http_token` was the old spelling, and config files holding it are on
      // disk on machines nobody is going to edit today. Read rather than
      // migrated.
      bearerToken:
          pick('bearer_token', 'SUMMAREADER_MCP_TOKEN') ??
          pick('http_token', 'SUMMAREADER_MCP_TOKEN'),
      host: pick('host', 'SUMMAREADER_MCP_HOST') ?? '127.0.0.1',
      port: int.tryParse(pick('port', 'SUMMAREADER_MCP_PORT') ?? '') ?? 8100,
    );
  }

  /// Write the address back, and nothing else.
  ///
  /// Every other key is put back exactly as it was read, including the ones
  /// this version has never heard of and the `_token`-style comment keys the
  /// example file uses — the file belongs to the person, not to this window.
  /// The master key and the bearer token are among them: they are copied
  /// through untouched, never parsed, never shown and never edited here.
  ///
  /// Through a temporary file and a rename, so an interrupted write leaves the
  /// old file whole. Half of a config file is a lost master key.
  ///
  /// A file that will not parse is a refusal naming the error and the path:
  /// the alternative is overwriting somebody's typo'd config with two keys and
  /// nothing else in it.
  void saveBind({required String host, required int port}) =>
      save({'host': host, 'port': port});

  /// Where the library is, and whether this mirror owns it.
  ///
  /// Two different keys, because they are two different arrangements and the
  /// difference is the whole question the switch asks. `library` is somebody
  /// else's file — the app's own — opened read-only, which is why it needs no
  /// server, token or master key. `cache_dir` is this mirror's own copy, which
  /// it fills by pulling and decrypting, and which does not exist until it
  /// does. Setting either clears the other: a config naming both would have
  /// two answers to "which library", and `config.py` would take the read-only
  /// one, which is not what somebody asking for a new one meant.
  void saveLibrary({String? library, String? cacheDir}) => save(
    library != null
        ? {'library': library, 'cache_dir': null}
        : {'cache_dir': cacheDir, 'library': null},
  );

  /// Writes these keys and leaves the rest of the file exactly as it was.
  ///
  /// A null value removes a key rather than writing `null` into it, because
  /// `config.py` reads a present-but-empty value as a value.
  void save(Map<String, Object?> updates) {
    final handle = File(file);
    var stored = <String, dynamic>{};
    if (handle.existsSync()) {
      final Object? decoded;
      try {
        decoded = jsonDecode(handle.readAsStringSync());
      } on FormatException catch (error) {
        throw StateError(
          '$file is not valid JSON (${error.message}) — '
          'nothing written. Fix it and try again.',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw StateError('$file is not a JSON object — nothing written.');
      }
      // jsonDecode keeps the order it read, so the file comes back out in the
      // order somebody wrote it, with these two appended the first time.
      stored = decoded;
    }
    for (final entry in updates.entries) {
      if (entry.value == null) {
        stored.remove(entry.key);
        // The comment beside it goes too, or the file explains a key it no
        // longer has.
        stored.remove('_${entry.key}');
      } else {
        stored[entry.key] = entry.value;
      }
    }
    final temp = File('$file.writing');
    temp.parent.createSync(recursive: true);
    temp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(stored)}\n',
      flush: true,
    );
    temp.renameSync(file);
  }
}

/// A whole configuration, pasted in one piece.
///
/// The three values a mirror needs were hand-edited into the file and nothing
/// else, which is a base64 key retyped across a desk — the one transcription
/// in this project where a wrong character costs a library that will not
/// decrypt. The app already puts exactly these on the clipboard (Settings →
/// Sync → Add another device → Copy MCP config), and its pairing code carries
/// the same values under different names.
///
/// Both spellings are read, and the letters version 1 used as well, because
/// the code on the other screen was drawn by whatever release that machine is
/// running and pairing is the worst moment to find out the two are a release
/// apart.
///
/// This is the only route by which this window writes a master key, and it is
/// acceptable for the reason a field would not be: the whole payload is
/// accepted at once, unread and unshown, or refused as a whole. Nothing here
/// ever puts the key on screen or in a message — see [refusal], which names
/// the length of a bad key and never its contents.
class Pairing {
  const Pairing._({this.keys, this.refusal});

  /// What to hand [MirrorConfig.save] — `server`, `token`, `master_key` and
  /// `name` together. Null when [refusal] is not.
  final Map<String, Object?>? keys;

  /// A sentence saying what was wrong, or null. Modelled on `libraryRefusal`:
  /// a payload that will not do is a sentence, and nothing is written.
  final String? refusal;

  static const _refused = 'Nothing has been changed.';

  static Pairing read(String pasted) {
    final text = pasted.trim();
    if (text.isEmpty) {
      return const Pairing._(
        refusal:
            'Nothing to pair with — no configuration on the clipboard and '
            'nothing typed. $_refused',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      return Pairing._(
        refusal:
            'That is not JSON (${error.message}). In the app, Settings → Sync '
            '→ Add another device → Copy MCP config puts the whole thing on '
            'the clipboard. $_refused',
      );
    }
    if (decoded is! Map) {
      return const Pairing._(
        refusal: 'That JSON is not an object, so it names no keys. $_refused',
      );
    }

    // Bound once, because a closure cannot see the check above: `decoded` is
    // typed as anything jsonDecode might have returned.
    final json = decoded;
    Object? field(List<String> names) {
      for (final name in names) {
        if (json.containsKey(name)) return json[name];
      }
      return null;
    }

    // A pairing code says which version it is; the config the app copies has
    // no version at all, and demanding one would refuse the very thing the
    // Copy MCP config button exists to produce.
    final version = field(['version', 'v']);
    if (version != null && version != 1 && version != 2) {
      return Pairing._(
        refusal:
            'That code says version $version, which this console does not '
            'know how to read. $_refused',
      );
    }

    final server = _pasted(field(['server', 'u']));
    final token = _pasted(field(['token', 'device_token', 't']));
    final key = _pasted(field(['master_key', 'k']));
    // Named rather than counted, as `missing` does it: half a configuration
    // written into the file is a mirror that still does not start, and now
    // nobody can see which half was missing.
    final absent = [
      if (server == null) 'the sync server',
      if (token == null) 'the device token',
      if (key == null) 'the master key',
    ];
    if (absent.isNotEmpty) {
      return Pairing._(
        refusal:
            'That leaves out ${absent.join(', ')}. A code a server shows '
            'carries no key, and a config needs all three. $_refused',
      );
    }

    final int length;
    try {
      length = base64.decode(key!).length;
    } on FormatException {
      return Pairing._(
        refusal:
            'The master key is not base64, so this is not one of our '
            'payloads. $_refused',
      );
    }
    if (length != 32) {
      // The length and never the value: a refusal is a message on screen, and
      // this one is about the key itself.
      return Pairing._(
        refusal: 'The master key decodes to $length bytes, not 32. $_refused',
      );
    }

    return Pairing._(
      keys: {
        'server': server,
        'token': token,
        'master_key': key,
        // What the app calls it when nobody named it, so the paired-devices
        // list has something to show rather than a blank row.
        'name': _pasted(field(['name', 'from_device', 'd'])) ?? 'MCP mirror',
      },
    );
  }
}

/// A value only when it is a non-empty string: `config.py` reads a
/// present-but-empty value as a value, and writing one would be a config that
/// looks complete and does not start.
String? _pasted(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

String? _first(Map<String, String> env, List<String> keys) {
  for (final key in keys) {
    final value = env[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Where this platform lets an unprivileged program keep things — the same
/// three answers `config.py` gives, so both find one file.
///
/// The second of the pair is the **data** directory, and was the cache one
/// until the library moved out of ~/.cache: a mirror runs no retention, so it
/// is the most complete copy of a library rather than a subset of one, and
/// ~/.cache is what a disk cleaner empties. It is still *spelled* cache
/// everywhere — see `config.py`, which explains why renaming it is not worth
/// what it would cost.
///
/// These two must move together. A window that opens a different library from
/// the server it supervises reports an empty mirror that is syncing fine.
(String, String) _home(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  if (Platform.isWindows) {
    final roaming = env['APPDATA'] ?? '$home/AppData/Roaming';
    final local = env['LOCALAPPDATA'] ?? '$home/AppData/Local';
    return ('$roaming/$_name', '$local/$_name');
  }
  if (Platform.isMacOS) {
    // One directory for both, which is what this platform offers.
    final base = '$home/Library/Application Support/$_name';
    return (base, base);
  }
  return (
    '${_first(env, ['XDG_CONFIG_HOME']) ?? '$home/.config'}/$_name',
    '${_xdgDataHome(env, home)}/$_name',
  );
}

/// XDG_DATA_HOME when it is absolute, else the ~/.local/share it defines.
///
/// Relative is ignored rather than resolved, as the specification requires:
/// resolving one against the working directory is how a window started from
/// two different shells opens two different libraries.
String _xdgDataHome(Map<String, String> env, String home) {
  final named = _first(env, ['XDG_DATA_HOME']) ?? '';
  return named.startsWith('/') ? named : '$home/.local/share';
}

String defaultConfigPath([Map<String, String>? environment]) =>
    '${_home(environment ?? Platform.environment).$1}/$_name.json';

String defaultCacheDir([Map<String, String>? environment]) =>
    _home(environment ?? Platform.environment).$2;

/// What the console was started with.
///
/// The same four flags the `gui` subcommand took, hand-parsed: an argument
/// parser for four options is a dependency to explain in a review.
class Options {
  const Options({this.config, this.library, this.remote, this.host, this.port});

  final String? config;
  final String? library;
  final String? remote;

  /// Null when nothing was typed, rather than the default — otherwise a flag
  /// nobody passed would win over the address in the config file. Flag, then
  /// environment, then file, then default; the last three are
  /// [MirrorConfig.load]'s order already.
  final String? host;
  final int? port;

  factory Options.parse(List<String> argv) {
    final values = <String, String>{};
    for (var i = 0; i < argv.length; i++) {
      final word = argv[i];
      if (!word.startsWith('--')) continue;
      final equals = word.indexOf('=');
      if (equals > 0) {
        values[word.substring(2, equals)] = word.substring(equals + 1);
      } else if (i + 1 < argv.length) {
        values[word.substring(2)] = argv[++i];
      }
    }
    return Options(
      config: values['config'],
      library: values['library'],
      remote: values['remote'],
      host: values['host'],
      port: int.tryParse(values['port'] ?? ''),
    );
  }

  MirrorConfig get configuration {
    if (remote != null) {
      return MirrorConfig.forRemote(
        remote!,
        token: Platform.environment['SUMMAREADER_MCP_TOKEN'],
      );
    }
    if (library != null) return MirrorConfig.forLibrary(library!);
    return MirrorConfig.load(file: config);
  }
}
