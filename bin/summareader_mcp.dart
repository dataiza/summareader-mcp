import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:summareader_core/summareader_core.dart';
import 'package:summareader_mcp/src/config.dart';
import 'package:summareader_mcp/src/library_mirror.dart';
import 'package:summareader_mcp/src/metrics.dart';
import 'package:summareader_mcp/src/mirror_store.dart';
import 'package:summareader_mcp/src/tools.dart';
import 'package:args/args.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// An MCP server over a SummaReader library.
///
/// Two transports, for two quite different situations. **stdio** is how a
/// local MCP client runs a server: as a subprocess it owns, with no port and
/// no network. **HTTP** is for a container, where a subprocess is not
/// something the client can start.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('transport',
        allowed: ['stdio', 'http'],
        defaultsTo: 'stdio',
        help: 'stdio for a local client; http inside a container.')
    ..addOption('port', defaultsTo: '8100')
    ..addOption('config', help: 'Overrides SUMMAREADER_MCP_CONFIG.')
    ..addFlag('help', negatable: false);

  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout.writeln('summareader-mcp — an MCP server over your reading library.');
    stdout.writeln(parser.usage);
    return;
  }

  final McpConfig config;
  try {
    config = await McpConfig.load(
      file: args.option('config') == null ? null : File(args.option('config')!),
    );
  } on McpConfigError catch (e) {
    // To stderr, always: on stdio the protocol owns stdout, and a message
    // printed there would be parsed as a malformed frame rather than read.
    stderr.writeln('summareader-mcp: $e');
    exitCode = 64;
    return;
  }

  final mirror = LibraryMirror(
    backend: PocketBaseSyncBackend(
      baseUrl: config.serverUrl,
      deviceToken: config.deviceToken,
    ),
    keys: await SyncKeys.derive(config.masterKey),
  );

  // What the last run left, before asking the server for anything. Restoring
  // is what turns startup from "re-read and re-decrypt the whole log" into
  // "ask for what arrived since".
  final store = MirrorStore(config.cacheDir);
  await store.restore(mirror);

  // Read once before answering anything. A server that comes up empty and
  // fills in later gives its first caller a wrong answer rather than a slow
  // one, which is the worse of the two.
  await _pull(mirror, store);

  // And then keep up. The log is append-only, so this is cheap: everything
  // already read is skipped by sequence number.
  Timer.periodic(const Duration(minutes: 5), (_) => _pull(mirror, store));

  final server = McpServer(
    const Implementation(name: 'summareader', version: '0.1.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );
  LibraryTools(mirror).registerOn(server);

  if (args.option('transport') == 'http') {
    await _serveHttp(
      server,
      int.parse(args.option('port')!),
      config.httpToken,
      mirror,
    );
  } else {
    await server.connect(StdioServerTransport());
  }
}

Future<void> _pull(LibraryMirror mirror, MirrorStore store) async {
  try {
    final applied = await mirror.pull();
    // Counted whether or not anything arrived: "the mirror is up to date" and
    // "the mirror stopped reading" look identical from the item count alone,
    // and they are the two states worth telling apart.
    pulls++;
    lastPull = DateTime.now();
    if (applied > 0) {
      stderr.writeln('summareader-mcp: read $applied entries');
      // Only when something changed. Rewriting an identical file on every
      // tick is disk churn for nothing.
      await store.save(mirror);
    }
  } catch (e) {
    // A sync server that is down is a reason to answer from what we have,
    // not a reason to stop answering.
    pullFailures++;
    stderr.writeln('summareader-mcp: could not reach the sync server: $e');
  }
}

/// The container transport.
///
/// Bound to every interface because inside a container localhost means the
/// container. What is exposed is decided by the port mapping, which is where
/// that decision belongs.
Future<void> _serveHttp(
  McpServer server,
  int port,
  String? token,
  LibraryMirror mirror,
) async {
  final transport = StreamableHTTPServerTransport(
    options: StreamableHTTPServerTransportOptions(
      sessionIdGenerator: () => generateUUID(),
    ),
  );
  await server.connect(transport);

  final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stderr.writeln('summareader-mcp: listening on $port');
  if (token == null) {
    // Said at startup rather than left to be discovered. The encryption ends
    // at this process — that is what it is for — so an open port here is the
    // whole library in plaintext to anybody who can reach it.
    stderr.writeln(
      'summareader-mcp: WARNING — no http_token set, so this port is open to '
      'anyone who can reach it, and it serves the entire library in '
      'plaintext. Only acceptable bound to localhost.',
    );
  }

  await for (final request in http) {
    // Metrics need the token. Health does not — see below — but these are
    // counts of somebody's library, and this process is the one place the
    // library exists in plaintext. Same token as the tools: a scraper that
    // can reach this port can already ask for the articles themselves, so a
    // second credential would be ceremony rather than security.
    if (request.uri.path == '/metrics') {
      if (!_authorised(request, token)) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('www-authenticate', 'Bearer')
          ..write('{"error":"a bearer token is required"}');
        await request.response.close();
        continue;
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'utf-8',
          parameters: {'version': '0.0.4'},
        )
        ..write(mcpMetrics(mirror));
      await request.response.close();
      continue;
    }

    // Health needs no token: it says whether the process is up and nothing
    // about what it holds, and a health check that needs a secret is a health
    // check that stops working the day the secret rotates.
    if (request.uri.path == '/health') {
      request.response
        ..statusCode = 200
        ..write('ok');
      await request.response.close();
      continue;
    }

    if (!_authorised(request, token)) {
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.set('www-authenticate', 'Bearer')
        ..write('{"error":"a bearer token is required"}');
      await request.response.close();
      continue;
    }

    final body = request.method == 'POST'
        ? jsonDecode(await utf8.decodeStream(request))
        : null;
    await transport.handleRequest(request, body);
  }
}

/// Whether a request may be answered.
///
/// No token configured means everything is allowed, which is the prototype
/// default and is warned about at startup. A token configured means it must
/// match exactly — there is no partial credit and no other way in.
bool _authorised(HttpRequest request, String? token) {
  if (token == null) return true;
  final header = request.headers.value(HttpHeaders.authorizationHeader);
  if (header == null) return false;

  const prefix = 'Bearer ';
  final presented =
      header.startsWith(prefix) ? header.substring(prefix.length) : header;
  return presented.trim() == token;
}
