import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:allreader_core/allreader_core.dart';
import 'package:allreader_mcp/src/config.dart';
import 'package:allreader_mcp/src/library_mirror.dart';
import 'package:allreader_mcp/src/tools.dart';
import 'package:args/args.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// An MCP server over an AllReader library.
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
    ..addOption('config', help: 'Overrides ALLREADER_MCP_CONFIG.')
    ..addFlag('help', negatable: false);

  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout.writeln('allreader-mcp — an MCP server over your reading library.');
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
    stderr.writeln('allreader-mcp: $e');
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

  // Read once before answering anything. A server that comes up empty and
  // fills in later gives its first caller a wrong answer rather than a slow
  // one, which is the worse of the two.
  await _pull(mirror);

  // And then keep up. The log is append-only, so this is cheap: everything
  // already read is skipped by sequence number.
  Timer.periodic(const Duration(minutes: 5), (_) => _pull(mirror));

  final server = McpServer(
    const Implementation(name: 'allreader', version: '0.1.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );
  LibraryTools(mirror).registerOn(server);

  if (args.option('transport') == 'http') {
    await _serveHttp(server, int.parse(args.option('port')!));
  } else {
    await server.connect(StdioServerTransport());
  }
}

Future<void> _pull(LibraryMirror mirror) async {
  try {
    final applied = await mirror.pull();
    if (applied > 0) stderr.writeln('allreader-mcp: read $applied entries');
  } catch (e) {
    // A sync server that is down is a reason to answer from what we have,
    // not a reason to stop answering.
    stderr.writeln('allreader-mcp: could not reach the sync server: $e');
  }
}

/// The container transport.
///
/// Bound to every interface because inside a container localhost means the
/// container. What is exposed is decided by the port mapping, which is where
/// that decision belongs.
Future<void> _serveHttp(McpServer server, int port) async {
  final transport = StreamableHTTPServerTransport(
    options: StreamableHTTPServerTransportOptions(
      sessionIdGenerator: () => generateUUID(),
    ),
  );
  await server.connect(transport);

  final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stderr.writeln('allreader-mcp: listening on $port');

  await for (final request in http) {
    // Unauthenticated, and therefore never to be exposed beyond localhost or
    // a private network. Anyone who can reach this port can read the whole
    // library — the encryption stops at this process, which is the point of
    // it and the reason it needs a boundary of its own.
    if (request.uri.path == '/health') {
      request.response
        ..statusCode = 200
        ..write('ok');
      await request.response.close();
      continue;
    }

    final body = request.method == 'POST'
        ? jsonDecode(await utf8.decodeStream(request))
        : null;
    await transport.handleRequest(request, body);
  }
}
