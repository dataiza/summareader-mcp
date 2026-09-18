/// The picture in the documentation, rendered rather than photographed.
///
/// The window this replaces needed a display, a window manager that would
/// leave it its own size, and ImageMagick to point at it — three things a
/// build machine does not have, which is why that picture was taken by hand
/// once and was quietly wrong afterwards. Flutter draws to a canvas with no
/// display at all, so this one is a test: it fails when the console stops
/// looking like the file in docs/, and regenerates it on request.
///
///     flutter test --update-goldens
///
/// The library underneath is the one scripts/screenshot.py describes, so the
/// console's picture and the terminal interface's are of the same reading.
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:summareader_ui/summareader_ui.dart';
import 'package:summareader_mcp_console/src/addresses.dart';
import 'package:summareader_mcp_console/src/console.dart';
import 'package:summareader_mcp_console/src/library.dart';
import 'package:summareader_mcp_console/src/mirror.dart';

import 'seed.dart';

/// The app's own faces, which the test harness does not load for itself:
/// without this every string is drawn in the placeholder font and the picture
/// documents a layout rather than a design.
///
/// Reading them is real file I/O, and a widget test runs on a fake clock that
/// never gets round to real I/O — hence `runAsync` around this and around the
/// queries below. Without it the test does not fail; it simply never finishes,
/// which is a worse afternoon.
Future<void> loadFonts() async {
  // The icon font comes out of the SDK, where the toolchain keeps it for
  // every application built with `uses-material-design`. Without it every
  // icon in the picture is an empty box.
  final sdk = Platform.environment['FLUTTER_ROOT'];
  for (final family in {
    'Caprasimo': 'assets/fonts/Caprasimo-Regular.ttf',
    'Figtree': 'assets/fonts/Figtree-Variable.ttf',
    if (sdk != null)
      'MaterialIcons':
          '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  }.entries) {
    if (!File(family.value).existsSync()) continue;
    final loader = FontLoader(family.key)
      ..addFont(
        File(family.value)
            .readAsBytes()
            .then((bytes) => bytes.buffer.asByteData()),
      );
    await loader.load();
  }
}

void main() {
  testWidgets('docs/console.png', (tester) async {
    await tester.runAsync(loadFonts);

    final temporary = Directory.systemTemp.createTempSync('console-golden');
    addTearDown(() => temporary.deleteSync(recursive: true));
    seedLibrary('${temporary.path}/library.sqlite');
    final library = LocalLibrary.open('${temporary.path}/library.sqlite');
    addTearDown(library.close);

    // The stats and the results come out of the real library through the real
    // queries. A picture assembled from hand-written strings would keep
    // looking right after the code stopped being.
    final counts = (await tester.runAsync(library.counts))!;
    final cursor = await tester.runAsync(() => library.setting('sync.cursor'));
    final found = (await tester.runAsync(() => library.search('')))!;

    final state = ConsoleState(
      status: statusLine(
        running: true,
        url: 'http://127.0.0.1:8100',
        managed: true,
      ),
      running: true,
      local: true,
      atLogin: true,
      stats: formatStats(
        counts,
        cursor,
        // What a mirror that has been running an hour looks like, rather than
        // whatever the machine taking the picture happens to have done.
        const Scraped(pulls: 14, failures: 0, lastPullAge: 240),
        // And a fixed clock to subtract that age from, or the picture would
        // differ from the one taken yesterday by exactly a day.
        DateTime.utc(2026, 8, 12, 9, 15),
      ),
      // Where a real installation keeps these, rather than the temporary
      // directory actually being read: the picture is of the program, and
      // nobody's home directory belongs in it.
      configRows: const [
        ('File', '/home/you/.config/summareader-mcp/summareader-mcp.json'),
        ('Library', '/home/you/.cache/summareader-mcp/library.sqlite'),
        ('Sync server', 'https://sync.example.com'),
        ('Name', 'MCP server'),
        ('Bearer token', 'set'),
      ],
      results: found.take(4).toList(),
      // A made-up interface list, for the same reason the paths above are
      // made up: the picture is of the program, not of the machine that
      // happened to render it.
      host: '127.0.0.1',
      port: 8100,
      hosts: bindHosts('127.0.0.1', const [
        LanAddr('192.168.1.24', 'wlan0'),
        LanAddr('172.17.0.1', 'docker0'),
      ]),
    );

    // Shorter than it was: the server, the address and the configuration are
    // behind the menu now, and a picture of the window has nothing to show in
    // the half of it they used to fill.
    tester.view.physicalSize = const Size(1060, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: Ar.themeData(),
        debugShowCheckedModeBanner: false,
        home: ConsoleView(
          state: state,
          query: TextEditingController(text: 'rust'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(ConsoleView),
      matchesGoldenFile('../../docs/console.png'),
    );
  });
}
