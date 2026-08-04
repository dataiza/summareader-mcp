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
        environment: {'ALLREADER_SYNC_URL': 'https://from-env.example'},
        cacheDir: dir,
      );

      expect(config.serverUrl, 'https://from-env.example');
    });

    test('the environment alone is enough', () async {
      final config = await McpConfig.load(
        file: File('${dir.path}/absent.json'),
        environment: {
          'ALLREADER_SYNC_URL': 'https://sync.example',
          'ALLREADER_DEVICE_TOKEN': 'a-token',
          'ALLREADER_MASTER_KEY': key,
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
          allOf(contains('ALLREADER_SYNC_URL'), contains('master key')),
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
}
