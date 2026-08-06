import 'dart:convert';
import 'dart:io';

import 'package:summareader_core/summareader_core.dart';
import 'package:summareader_mcp/src/config.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('summareader-mcp-config');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<File> configFile(Map<String, Object?> contents) async {
    final file = File('${dir.path}/config.json');
    await file.writeAsString(jsonEncode(contents));
    return file;
  }

  final key = base64.encode(MasterKey.generate().bytes);

  group('reading configuration', () {
    test('takes all three from a file', () async {
      final config = await McpConfig.load(
        file: await configFile({
          'server': 'https://sync.example',
          'token': 'a-token',
          'master_key': key,
        }),
        environment: const {},
        cacheDir: dir,
      );

      expect(config.serverUrl, 'https://sync.example');
      expect(config.deviceToken, 'a-token');
      expect(config.masterKey.bytes, base64.decode(key));
    });

    test('the environment wins over the file', () async {
      // So a deployment can point at another server without editing a file
      // that may be mounted read-only.
      final config = await McpConfig.load(
        file: await configFile({
          'server': 'https://from-file.example',
          'token': 'a-token',
          'master_key': key,
        }),
        environment: {'SUMMAREADER_SYNC_URL': 'https://from-env.example'},
        cacheDir: dir,
      );

      expect(config.serverUrl, 'https://from-env.example');
    });

    test('the environment alone is enough', () async {
      final config = await McpConfig.load(
        file: File('${dir.path}/absent.json'),
        environment: {
          'SUMMAREADER_SYNC_URL': 'https://sync.example',
          'SUMMAREADER_DEVICE_TOKEN': 'a-token',
          'SUMMAREADER_MASTER_KEY': key,
        },
        cacheDir: dir,
      );

      expect(config.deviceToken, 'a-token');
    });
  });

  group('refusing to start', () {
    test('says what is missing and where to put it', () async {
      // The first thing anybody hits, so it has to be a sentence rather than
      // a stack trace.
      await expectLater(
        McpConfig.load(
          file: File('${dir.path}/absent.json'),
          environment: const {},
          cacheDir: dir,
        ),
        throwsA(isA<McpConfigError>().having(
          (e) => e.message,
          'message',
          allOf(contains('SUMMAREADER_SYNC_URL'), contains('master key')),
        )),
      );
    });

    test('a master key that is not base64', () async {
      await expectLater(
        McpConfig.load(
          file: await configFile({
            'server': 'https://sync.example',
            'token': 'a-token',
            'master_key': 'not base64 at all!!',
          }),
          environment: const {},
          cacheDir: dir,
        ),
        throwsA(isA<McpConfigError>()),
      );
    });

    test('a master key of the wrong length says how long it is', () async {
      // Pasting half a key is a thing people do, and "decrypts nothing" is a
      // miserable way to find out.
      await expectLater(
        McpConfig.load(
          file: await configFile({
            'server': 'https://sync.example',
            'token': 'a-token',
            'master_key': base64.encode(List.filled(16, 7)),
          }),
          environment: const {},
          cacheDir: dir,
        ),
        throwsA(isA<McpConfigError>()
            .having((e) => e.message, 'message', contains('16'))),
      );
    });
  });

  group('the names these had before the app was renamed', () {
    test('still work, because they are in somebody\'s compose file', () async {
      // An environment variable is written once and not read again. Renaming
      // one without a fallback means a deployment that has been running for
      // months comes back after a pull saying it needs a sync server, with
      // nothing to say the name moved.
      final config = await McpConfig.load(
        environment: {
          'ALLREADER_SYNC_URL': 'https://old.example',
          'ALLREADER_DEVICE_TOKEN': 'a-token',
          'ALLREADER_MASTER_KEY': base64Url.encode(List.filled(32, 7)),
        },
      );

      expect(config.serverUrl, 'https://old.example');
    });

    test('and the new name wins where both are set', () async {
      final config = await McpConfig.load(
        environment: {
          'ALLREADER_SYNC_URL': 'https://old.example',
          'SUMMAREADER_SYNC_URL': 'https://new.example',
          'SUMMAREADER_DEVICE_TOKEN': 'a-token',
          'SUMMAREADER_MASTER_KEY': base64Url.encode(List.filled(32, 7)),
        },
      );

      expect(config.serverUrl, 'https://new.example');
    });
  });
}
