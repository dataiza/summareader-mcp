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

  /// Pairing, which is the one thing in this window that writes a credential.
  ///
  /// Both spellings, because the app copies one and shows the other, and every
  /// refusal, because a payload that will not do has to leave the file exactly
  /// as it was — half a configuration is a mirror that does not start and says
  /// nothing about which half is missing.
  group('how often it pulls, and what guards the port', () {
    test('the interval is read like the mirror reads it', () {
      final file = write(dir, '{"poll_seconds": 900}');
      expect(
        MirrorConfig.load(file: file.path, environment: const {}).pollSeconds,
        900,
      );
      // The environment wins, the way every other key here does.
      expect(
        MirrorConfig.load(
          file: file.path,
          environment: const {'SUMMAREADER_MCP_POLL': '60'},
        ).pollSeconds,
        60,
      );
      // And nothing said is the default `config.py` holds, not zero.
      expect(
        MirrorConfig.load(
          file: '${dir.path}/absent.json',
          environment: const {},
        ).pollSeconds,
        300,
      );
    });

    test('writing either leaves the rest of the file alone', () {
      final file = write(dir, _full);
      MirrorConfig.load(file: file.path, environment: const {}).savePoll(120);
      MirrorConfig.load(
        file: file.path,
        environment: const {},
      ).saveBearerToken('generated');

      final after = MirrorConfig.load(file: file.path, environment: const {});
      expect(after.pollSeconds, 120);
      expect(after.bearerToken, 'generated');
      // Including the master key, which is the one this must never touch.
      expect(after.masterKey, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['_master_key'], 'NOT revocable.');
    });
  });

  group('pairing', () {
    // What Settings → Sync → Add another device → Copy MCP config puts on the
    // clipboard.
    const mcp =
        '{"server": "https://sync.example", "token": "device-token", '
        '"master_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", '
        '"name": "MCP mirror"}';

    // The same three values as the pairing code beside that button spells
    // them.
    const code =
        '{"version": 2, "master_key": '
        '"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", '
        '"from_device": "a laptop", "server": "https://sync.example", '
        '"device_token": "device-token"}';

    const key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

    test('the config the app copies', () {
      final read = Pairing.read(mcp);
      expect(read.refusal, isNull);
      expect(read.keys, {
        'server': 'https://sync.example',
        'token': 'device-token',
        'master_key': key,
        'name': 'MCP mirror',
      });
    });

    test('the pairing code, which spells the same values differently', () {
      final read = Pairing.read(code);
      expect(read.refusal, isNull);
      expect(read.keys!['server'], 'https://sync.example');
      expect(read.keys!['token'], 'device-token');
      expect(read.keys!['master_key'], key);
      // *Not* the device that showed the code. `from_device` is the name of
      // the machine on the other end of the pairing, and taking it named this
      // mirror after somebody's laptop in the app's device list.
      expect(read.keys!['name'], 'MCP mirror');
    });

    test('a version 1 code, in the letters that release wrote', () {
      // A code is read off whatever screen is in front of somebody, and
      // pairing is the worst moment to find out the two machines are a
      // release apart.
      final read = Pairing.read(
        '{"v": 1, "k": "$key", "u": "https://sync.example", '
        '"t": "device-token", "d": "Phone"}',
      );
      expect(read.refusal, isNull);
      expect(read.keys!['server'], 'https://sync.example');
      expect(read.keys!['token'], 'device-token');
      // `d` is the other device, like `from_device` — see above.
      expect(read.keys!['name'], 'MCP mirror');
    });

    test('an unnamed payload is still named in the file', () {
      final read = Pairing.read(
        '{"server": "https://sync.example", "token": "t", "master_key": '
        '"$key"}',
      );
      expect(read.keys!['name'], 'MCP mirror');
    });

    test('nothing on the clipboard and nothing typed', () {
      final read = Pairing.read('   ');
      expect(read.keys, isNull);
      expect(read.refusal, contains('Nothing to pair with'));
    });

    test('something that is not JSON at all', () {
      final read = Pairing.read('https://sync.example');
      expect(read.keys, isNull);
      expect(read.refusal, contains('not JSON'));
      // And says where the right thing comes from, rather than only what was
      // wrong with what was pasted.
      expect(read.refusal, contains('Copy MCP config'));
    });

    test('JSON that is not an object names no keys', () {
      expect(Pairing.read('[1, 2]').refusal, contains('not an object'));
    });

    test('a version this console does not know how to read', () {
      final read = Pairing.read(
        code.replaceFirst('"version": 2', '"version": 9'),
      );
      expect(read.keys, isNull);
      expect(read.refusal, contains('version 9'));
    });

    test('a code a server showed, which carries no key', () {
      // The server has never held the master key and must not, so the code
      // its window draws says where to sync and with which token, and that is
      // not a configuration.
      final read = Pairing.read(
        '{"version": 2, "server": "https://sync.example", '
        '"device_token": "device-token", "from_device": "the server"}',
      );
      expect(read.keys, isNull);
      expect(read.refusal, contains('the master key'));
    });

    test('each of the three is named when it is the one missing', () {
      expect(
        Pairing.read(mcp.replaceFirst('"server"', '"_server"')).refusal,
        contains('the sync server'),
      );
      expect(
        Pairing.read(mcp.replaceFirst('"token"', '"_t"')).refusal,
        contains('the device token'),
      );
      // Present but empty counts as missing: config.py reads an empty value
      // as a value, so a file written from one would look complete and still
      // not start.
      expect(
        Pairing.read(mcp.replaceFirst('"device-token"', '""')).refusal,
        contains('the device token'),
      );
    });

    test('a master key that is not base64', () {
      final read = Pairing.read(mcp.replaceFirst(key, 'not a key'));
      expect(read.keys, isNull);
      expect(read.refusal, contains('not base64'));
    });

    test('a master key of the wrong length, named by its length only', () {
      final read = Pairing.read(mcp.replaceFirst(key, 'AAAA'));
      expect(read.keys, isNull);
      expect(read.refusal, contains('3 bytes, not 32'));
      // Never the key itself. A refusal is a sentence on somebody's screen.
      expect(read.refusal, isNot(contains('AAAA')));
    });

    test('pairing writes all four keys and leaves the rest of the file', () {
      final file = write(dir, _full);
      final read = Pairing.read(code);
      MirrorConfig.load(
        file: file.path,
        environment: const {},
      ).save(read.keys!);

      final after = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(after['server'], 'https://sync.example');
      expect(after['token'], 'device-token');
      expect(after['master_key'], key);
      expect(after['name'], 'MCP mirror');
      // The comment keys, the unknown key and the old bearer-token spelling
      // belong to the person, not to this window.
      expect(after['_master_key'], 'NOT revocable.');
      expect(after['http_token'], 's3cret');
      expect(after['something_this_version_never_heard_of'], {
        'nested': [1, 2],
      });
    });

    test('a refused payload writes nothing', () {
      final file = write(dir, _full);
      final before = file.readAsStringSync();
      for (final pasted in ['', 'not json', '[1]', '{"server": "x"}']) {
        final read = Pairing.read(pasted);
        expect(read.refusal, isNotNull, reason: pasted);
        expect(read.keys, isNull, reason: pasted);
      }
      expect(file.readAsStringSync(), before);
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
