/// The config file, read and — for two keys — written.
///
/// The writing is the part worth a test: this file holds somebody's master
/// key, and a window that rewrites it badly is a window that loses it. So the
/// questions here are what survives a round trip, and what refuses to happen.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    expect(Options.parse(const ['--host=0.0.0.0', '--port', '9000']).host,
        '0.0.0.0');
    expect(Options.parse(const ['--host=0.0.0.0', '--port', '9000']).port, 9000);
  });
}
