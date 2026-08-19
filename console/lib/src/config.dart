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
    this.server,
    this.token,
    this.masterKey,
    this.instanceName,
    this.bearerToken,
    this.library,
    this.remote,
    this.host = '127.0.0.1',
    this.port = 8100,
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

  String get database => library ?? '$cacheDir/library.sqlite';

  bool get readsALocalLibrary => library != null;

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
    remote: url,
    bearerToken: token,
  );

  /// A library file that is already here: no server, no keys, no second copy.
  factory MirrorConfig.forLibrary(String path) => MirrorConfig(
    file: '(none — reading $path)',
    cacheDir: File(path).parent.path,
    library: path,
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

    return MirrorConfig(
      file: path,
      cacheDir: pick('cache_dir', 'SUMMAREADER_MCP_CACHE') ?? defaultCacheDir(env),
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
  void saveBind({required String host, required int port}) {
    final handle = File(file);
    var stored = <String, dynamic>{};
    if (handle.existsSync()) {
      final Object? decoded;
      try {
        decoded = jsonDecode(handle.readAsStringSync());
      } on FormatException catch (error) {
        throw StateError('$file is not valid JSON (${error.message}) — '
            'nothing written. Fix it and try again.');
      }
      if (decoded is! Map<String, dynamic>) {
        throw StateError('$file is not a JSON object — nothing written.');
      }
      // jsonDecode keeps the order it read, so the file comes back out in the
      // order somebody wrote it, with these two appended the first time.
      stored = decoded;
    }
    stored['host'] = host;
    stored['port'] = port;
    final temp = File('$file.writing');
    temp.parent.createSync(recursive: true);
    temp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(stored)}\n',
      flush: true,
    );
    temp.renameSync(file);
  }
}

String? _first(Map<String, String> env, List<String> keys) {
  for (final key in keys) {
    final value = env[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Where this platform lets an unprivileged program keep things — the same
/// three answers `config.py` gives, so both find one file.
(String, String) _home(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  if (Platform.isWindows) {
    final roaming = env['APPDATA'] ?? '$home/AppData/Roaming';
    final local = env['LOCALAPPDATA'] ?? '$home/AppData/Local';
    return ('$roaming/$_name', '$local/$_name/cache');
  }
  if (Platform.isMacOS) {
    return (
      '$home/Library/Application Support/$_name',
      '$home/Library/Caches/$_name',
    );
  }
  return (
    '${_first(env, ['XDG_CONFIG_HOME']) ?? '$home/.config'}/$_name',
    '${_first(env, ['XDG_CACHE_HOME']) ?? '$home/.cache'}/$_name',
  );
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
