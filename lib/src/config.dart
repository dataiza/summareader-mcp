import 'dart:convert';
import 'dart:io';

import 'package:summareader_core/summareader_core.dart';

/// Everything this server needs to be a device.
///
/// Three secrets, and they are not equally secret. The server URL is public.
/// The device token grants sync access and can be revoked from any paired
/// device. **The master key decrypts the entire library** and cannot be
/// revoked — it is the one that matters.
class McpConfig {
  const McpConfig({
    required this.serverUrl,
    required this.deviceToken,
    required this.masterKey,
    required this.cacheDir,
    this.httpToken,
  });

  final String serverUrl;
  final String deviceToken;
  final MasterKey masterKey;

  /// Where the decrypted copy lives. Plaintext, deliberately a cache.
  final Directory cacheDir;

  /// A bearer token callers of the HTTP transport must present.
  ///
  /// Null means anyone who can reach the port can read the whole library,
  /// which is tolerable bound to localhost and nowhere else. The server says
  /// so at startup rather than leaving it to be discovered.
  final String? httpToken;

  /// Reads configuration from a file, with the environment as an override.
  ///
  /// A file rather than environment variables for the secrets, because
  /// `docker inspect` prints an environment and `ps` can print another
  /// process's. A file can be mounted read-only and given restrictive
  /// permissions, and it is what Docker secrets are.
  ///
  /// The environment is still honoured for the URL and for pointing at the
  /// file itself, because those are not secret and are the ergonomic half.
  static Future<McpConfig> load({
    File? file,
    Map<String, String>? environment,
    Directory? cacheDir,
  }) async {
    final env = environment ?? Platform.environment;
    final path = env['SUMMAREADER_MCP_CONFIG'] ?? env['ALLREADER_MCP_CONFIG'] ?? '/config/summareader-mcp.json';
    final source = file ?? File(path);

    Map<String, dynamic> stored = const {};
    if (await source.exists()) {
      final decoded = jsonDecode(await source.readAsString());
      if (decoded is Map<String, dynamic>) stored = decoded;
    }

    /// The variable, the name it had before the app was renamed, then the
    /// file.
    ///
    /// The old names keep working on purpose. An environment variable is
    /// somebody's compose file or unit file, written once and not read again
    /// — renaming it without a fallback means a deployment that has been
    /// running for months comes back after a pull with "needs a sync server"
    /// and no clue that the name moved.
    String? pick(String key, String envKey) {
      for (final name in [envKey, envKey.replaceFirst('SUMMAREADER_', 'ALLREADER_')]) {
        final fromEnv = env[name]?.trim();
        if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
      }
      final value = stored[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final token = pick('http_token', 'SUMMAREADER_MCP_TOKEN');
    final url = pick('server', 'SUMMAREADER_SYNC_URL');
    final deviceToken = pick('token', 'SUMMAREADER_DEVICE_TOKEN');
    final key = pick('master_key', 'SUMMAREADER_MASTER_KEY');

    if (url == null || deviceToken == null || key == null) {
      throw McpConfigError(
        'Needs a sync server, a device token and a master key. '
        'Put them in ${source.path} as {"server": …, "token": …, '
        '"master_key": …}, or set SUMMAREADER_SYNC_URL, '
        'SUMMAREADER_DEVICE_TOKEN and SUMMAREADER_MASTER_KEY.',
      );
    }

    return McpConfig(
      serverUrl: url,
      deviceToken: deviceToken,
      httpToken: token,
      masterKey: _masterKeyFrom(key),
      cacheDir: cacheDir ??
          Directory(env['SUMMAREADER_MCP_CACHE'] ??
              env['ALLREADER_MCP_CACHE'] ??
              '/cache'),
    );
  }
}

/// The same encoding the pairing payload uses — base64 of the 32 raw bytes.
///
/// Matching it matters: this is how a master key gets from the app to here,
/// and a second encoding would mean a key that pastes cleanly and then
/// decrypts nothing, with no error to explain why.
MasterKey _masterKeyFrom(String encoded) {
  final List<int> bytes;
  try {
    bytes = base64.decode(encoded);
  } on FormatException {
    throw const McpConfigError('The master key is not valid base64.');
  }
  if (bytes.length != 32) {
    throw McpConfigError(
      'A master key is 32 bytes; this one is ${bytes.length}.',
    );
  }
  return MasterKey(bytes);
}

class McpConfigError implements Exception {
  const McpConfigError(this.message);
  final String message;

  @override
  String toString() => message;
}
