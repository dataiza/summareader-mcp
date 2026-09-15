/// The config file, read and — for two keys — written.
///
/// The writing is the part worth a test: this file holds somebody's master
/// key, and a window that rewrites it badly is a window that loses it. So the
/// questions here are what survives a round trip, and what refuses to happen.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:summareader_mcp_console/src/first_run.dart';
import 'package:summareader_mcp_console/src/config.dart';

/// A config file with everything awkward in it: comment keys, a key this
/// version has never heard of, and the old spelling of the bearer token.
File write(Directory dir, String text) =>
    File('${dir.path}/summareader-mcp.json')..writeAsStringSync(text);

const _full = '''
{
  "_comment": "Copy to summareader-mcp.local.json and fill in.",
  "server": "https://sync.example",
  "_token": "From a paired device.",
  "token": "device-token",
  "_master_key": "NOT revocable.",
  "master_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  "http_token": "s3cret",
  "fetch_bodies": false,
  "something_this_version_never_heard_of": {"nested": [1, 2]}
}
''';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mcp-config'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('reading', () {
    test('loopback and 8100 when nobody says', () {
      final config = MirrorConfig.load(
        file: write(dir, _full).path,
        environment: const {},
      );
      expect(config.host, '127.0.0.1');
      expect(config.port, 8100);
    });

    test('the file, where a port is a number and not a string', () {
      final config = MirrorConfig.load(
        file: write(dir, '{"host": "0.0.0.0", "port": 9000}').path,
        environment: const {},
      );
      expect(config.host, '0.0.0.0');
      expect(config.port, 9000);
    });

    test('the environment wins over the file', () {
      final config = MirrorConfig.load(
        file: write(dir, '{"host": "0.0.0.0", "port": 9000}').path,
        environment: const {
          'SUMMAREADER_MCP_HOST': '10.0.0.5',
          'SUMMAREADER_MCP_PORT': '9999',
        },
      );
      expect(config.host, '10.0.0.5');
      expect(config.port, 9999);
    });

    test('the old spelling of the bearer token is still read', () {
      // It guards the port. Reading only the new spelling would show an
      // installation that has a token as one that has none.
      final config = MirrorConfig.load(
        file: write(dir, _full).path,
        environment: const {},
      );
      expect(config.bearerToken, 's3cret');
    });
  });

  group('writing the address back', () {
    test('keeps every other key, comments and unknowns alike', () {
      final file = write(dir, _full);
      MirrorConfig.load(
        file: file.path,
        environment: const {},
      ).saveBind(host: '0.0.0.0', port: 9000);

      final after = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final before = jsonDecode(_full) as Map<String, dynamic>;
      for (final key in before.keys) {
        expect(after[key], before[key], reason: '$key changed');
      }
      expect(after['host'], '0.0.0.0');
      expect(after['port'], 9000);
      // The order somebody wrote, with the two new keys appended.
      expect(after.keys.take(before.length), before.keys);
    });

    test('the master key and the bearer token come back byte for byte', () {
      final file = write(dir, _full);
      MirrorConfig.load(
        file: file.path,
        environment: const {},
      ).saveBind(host: '0.0.0.0', port: 9000);
      final after = MirrorConfig.load(file: file.path, environment: const {});
      expect(after.masterKey, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(after.bearerToken, 's3cret');
    });

    test('a malformed file is refused by name, and left alone', () {
      final file = write(dir, '{"server": "https://sync.example",,}');
      final before = file.readAsStringSync();
      expect(
        () => MirrorConfig.load(
          file: file.path,
          environment: const {},
        ).saveBind(host: '0.0.0.0', port: 9000),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains(file.path), contains('not valid JSON')),
          ),
        ),
      );
      expect(file.readAsStringSync(), before);
    });

    test('writes a file that was not there yet', () {
      final path = '${dir.path}/new/summareader-mcp.json';
      MirrorConfig.load(
        file: path,
        environment: const {},
      ).saveBind(host: '127.0.0.1', port: 9001);
      expect(MirrorConfig.load(file: path, environment: const {}).port, 9001);
    });

    test('leaves nothing beside the file it wrote', () {
      // The temporary is renamed, not left behind for the next reader to find.
      final file = write(dir, _full);
      MirrorConfig.load(
        file: file.path,
        environment: const {},
      ).saveBind(host: '0.0.0.0', port: 9000);
      expect(dir.listSync().map((e) => e.path), [file.path]);
    });
  });

  test('a flag that was not passed is null, not the default', () {
    // Otherwise the config file's address could never win over an argparse
    // default nobody typed.
    expect(Options.parse(const []).host, isNull);
    expect(Options.parse(const []).port, isNull);
    expect(
      Options.parse(const ['--host=0.0.0.0', '--port', '9000']).host,
      '0.0.0.0',
    );
    expect(
      Options.parse(const ['--host=0.0.0.0', '--port', '9000']).port,
      9000,
    );
  });

  group('where the library goes when nobody says', () {
    // Linux only: the branch is per-platform and this suite runs on one of
    // them. macOS puts both in Application Support and is asserted in
    // tests/test_config.py, which can state a platform rather than be one.
    test('the data directory, not the cache one', () {
      // It was XDG_CACHE_HOME. A mirror runs no retention, so it is the most
      // complete copy of a library rather than a subset of one — and ~/.cache
      // is exactly what a disk cleaner empties.
      final env = {
        'HOME': '/home/somebody',
        'XDG_CACHE_HOME': '/tmp/cache',
        'XDG_DATA_HOME': '',
      };
      expect(
        defaultCacheDir(env),
        '/home/somebody/.local/share/summareader-mcp',
      );
      expect(
        defaultCacheDir(env),
        isNot(contains('cache')),
        reason: 'the key is still spelled cache; the location must not be',
      );
    });

    test('an absolute XDG_DATA_HOME is followed, a relative one is not', () {
      const home = {'HOME': '/home/somebody'};
      expect(
        defaultCacheDir({...home, 'XDG_DATA_HOME': '/mnt/big/share'}),
        '/mnt/big/share/summareader-mcp',
      );
      expect(
        defaultCacheDir({...home, 'XDG_DATA_HOME': 'relative/share'}),
        '/home/somebody/.local/share/summareader-mcp',
        reason:
            'the specification says absolute, and resolving a relative one '
            'against the working directory opens two libraries',
      );
    });

    test('the config file did not move with it', () {
      final env = {'HOME': '/home/somebody', 'XDG_CONFIG_HOME': ''};
      expect(
        defaultConfigPath(env),
        '/home/somebody/.config/summareader-mcp/summareader-mcp.json',
      );
    });
  });

  group('whether anybody has said where', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('mcp-said'));
    tearDown(() => dir.deleteSync(recursive: true));

    File place(String text) =>
        File('${dir.path}/summareader-mcp.json')..writeAsStringSync(text);

    test('nothing said means nothing chosen', () {
      final config = MirrorConfig.load(
        file: place('{"server": "https://x.invalid"}').path,
        environment: const {},
      );
      expect(config.saidWhere, isFalse);
    });

    test('a cache_dir key counts', () {
      final config = MirrorConfig.load(
        file: place('{"cache_dir": "/srv/mirror"}').path,
        environment: const {},
      );
      expect(config.saidWhere, isTrue);
      expect(config.cacheDir, '/srv/mirror');
    });

    test('the environment counts, which is what the container passes', () {
      final config = MirrorConfig.load(
        file: place('{}').path,
        environment: const {'SUMMAREADER_MCP_CACHE': '/cache'},
      );
      expect(
        config.saidWhere,
        isTrue,
        reason: 'a container must never be asked a question',
      );
    });

    test('naming a library counts too', () {
      // The other way to say where: somebody reading an existing file has
      // answered the question in a different sentence.
      final config = MirrorConfig.load(
        file: place('{"library": "/home/you/library.sqlite"}').path,
        environment: const {},
      );
      expect(config.saidWhere, isTrue);
    });
  });

  group('emptying a library', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('mcp-empty'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('takes the library and its log, and leaves the config', () async {
      // On macOS the config file is in this directory too — one directory is
      // the whole installation there — and it holds the master key, which is
      // the one thing here that is not recoverable.
      for (final name in [
        'library.sqlite',
        'library.sqlite-wal',
        'library.sqlite-shm',
      ]) {
        File('${dir.path}/$name').writeAsStringSync('x');
      }
      File('${dir.path}/summareader-mcp.json').writeAsStringSync('{"a": 1}');

      expect(holdsALibrary(dir.path), isTrue);
      expect(await emptyLibrary(dir.path), isTrue);
      expect(holdsALibrary(dir.path), isFalse);
      expect(
        File('${dir.path}/summareader-mcp.json').existsSync(),
        isTrue,
        reason: 'the master key is in there',
      );
    });

    test('an empty directory is not a library', () async {
      expect(holdsALibrary(dir.path), isFalse);
      expect(await emptyLibrary(dir.path), isFalse);
    });
  });
}
