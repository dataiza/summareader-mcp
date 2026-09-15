/// The window, drawn.
///
/// `ConsoleView` is a function of `ConsoleState`, so the questions worth
/// asking of it are cheap: does a console pointed at somebody else's mirror
/// say so and refuse to run anything, is a credential ever printed, and do
/// the numbers reach the pane.
///
/// Since the window was split in two, the other question worth asking is
/// whether anything became unreachable: the settings are a menu away now, and
/// a control nobody can get to is worse than one that is merely dim.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summareader_ui/summareader_ui.dart';
import 'package:summareader_mcp_console/src/console.dart';
import 'package:summareader_mcp_console/src/library.dart';
import 'package:summareader_mcp_console/src/mirror.dart';

Future<void> draw(
  WidgetTester tester,
  ConsoleState state, {
  VoidCallback? onToggle,
}) async {
  tester.view.physicalSize = const Size(1100, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: Ar.themeData(),
      home: ConsoleView(
        state: state,
        query: TextEditingController(),
        onToggle: onToggle,
      ),
    ),
  );
}

ConsoleState reading(String? note, {bool local = false}) => ConsoleState(
  status: 'Not running — http://127.0.0.1:8100',
  running: false,
  note: note,
  local: local,
  stats: formatStats(const {'items': 3}, '7'),
  configRows: const [('File', '/home/you/config.json')],
);

/// Walks the top menu to the settings, which is where everything but the
/// library and the search box now lives.
Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Console'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the window opens on the library and the search box', (
    tester,
  ) async {
    await draw(tester, reading(null, local: true));

    expect(find.text('Library'), findsOneWidget);
    // Twice over: the heading, and the button beside the box.
    expect(find.text('Search'), findsWidgets);
    // The three that used to sit between them, and were the reason the search
    // results started below the fold.
    expect(find.text('The server'), findsNothing);
    expect(find.text('Address'), findsNothing);
    expect(find.text('Configuration'), findsNothing);
  });

  testWidgets('the menu reaches everything that moved', (tester) async {
    await draw(tester, reading(null, local: true));
    await openSettings(tester);

    expect(find.text('The server'), findsOneWidget);
    expect(find.text('Address'), findsOneWidget);
    expect(find.text('Configuration'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    // The library path is edited here, not read: it is the one line of the
    // configuration this window writes.
    expect(find.text('Its own copy'), findsOneWidget);
    expect(find.text('/home/you/config.json'), findsOneWidget);

    // And back again, or the settings are a one-way door.
    await tester.tap(find.text('Console'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library and Search'));
    await tester.pumpAndSettle();
    expect(find.text('Search'), findsWidgets);
  });

  testWidgets('a mirror it does not hold is greyed out with a reason', (
    tester,
  ) async {
    var started = false;
    await draw(
      tester,
      reading(refusal(remote: 'http://box:8100')),
      onToggle: () => started = true,
    );

    expect(find.textContaining('http://box:8100'), findsWidgets);
    // The sentence stays on the first screen as well as beside the buttons it
    // is about: a mirror that will not pull is the answer to "why has nothing
    // arrived", which is asked of the library, not of the settings.
    expect(find.textContaining('Start, Stop and Pull'), findsOneWidget);
    await openSettings(tester);

    // Not merely dim: pressing it has to do nothing. A disabled-looking button
    // that still starts a server is the worse half of this bug.
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(started, isFalse);
  });

  testWidgets('a library the app owns says what it will not do', (
    tester,
  ) async {
    await draw(tester, reading(refusal(library: '/home/you/library.sqlite')));
    // The refusal itself, not merely the words: the Library row's own hint
    // says "read-only" too, and matching that would pass with the sentence
    // this test exists for missing entirely.
    expect(find.textContaining('nothing to start'), findsOneWidget);
    expect(find.textContaining('nothing to pull'), findsOneWidget);
  });

  testWidgets('the numbers and the results are on the screen', (tester) async {
    await draw(
      tester,
      ConsoleState(
        status: 'Running on http://127.0.0.1:8100 (systemd)',
        running: true,
        local: true,
        stats: formatStats(
          const {'items': 1284, 'unread': 37, 'sources': 9},
          '418',
          const Scraped(failures: 0, lastPullAge: 90),
        ),
        configRows: const [('Bearer token', 'set')],
        results: [
          Item(
            id: 'a1',
            title: 'What the borrow checker actually proves',
            source: 'Lime',
            url: 'https://example.com/a1',
            published: DateTime.utc(2026, 8, 11),
          ),
        ],
      ),
    );

    expect(find.text('1284'), findsOneWidget);
    expect(find.text('418'), findsOneWidget);
    expect(find.text('1 minute ago'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('2026-08-11'), findsOneWidget);
    expect(
      find.text('What the borrow checker actually proves'),
      findsOneWidget,
    );

    await openSettings(tester);
    // The token is described, never printed. A window that shows a credential
    // is a window somebody screenshots.
    expect(find.text('set'), findsOneWidget);
  });
}
