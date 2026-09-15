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
import 'package:summareader_mcp_console/src/version.dart';
import 'package:summareader_mcp_console/src/library.dart';
import 'package:summareader_mcp_console/src/mirror.dart';

Future<void> draw(
  WidgetTester tester,
  ConsoleState state, {
  VoidCallback? onToggle,
  ValueChanged<String>? onPair,
  void Function({required bool existing})? onBrowse,
  ValueChanged<String>? onPoll,
  ValueChanged<bool>? onSyncing,
  VoidCallback? onGenerateToken,
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
        onPair: onPair,
        onBrowse: onBrowse,
        onPoll: onPoll,
        onSyncing: onSyncing,
        onGenerateToken: onGenerateToken,
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
  // One press. It was two — a menu bar holding one submenu called "Console",
  // with everything but the library behind that word.
  await tester.tap(find.text('Configuration'));
  await tester.pumpAndSettle();
}

void main() {
  _thisProgram();

  ConsoleState withAFile({bool syncing = true, bool ownsLibrary = true}) =>
      ConsoleState(
        status: 'Not running',
        running: false,
        local: ownsLibrary,
        ownsLibrary: ownsLibrary,
        stats: formatStats(const {'items': 3}, '7'),
        configRows: const [('File', '/home/you/config.json')],
        syncing: syncing,
        pollSeconds: 900,
      );

  testWidgets('the interval and the token are there when a file is', (
    tester,
  ) async {
    await draw(
      tester,
      withAFile(),
      onPoll: (_) {},
      onSyncing: (_) {},
      onGenerateToken: () {},
    );
    await openSettings(tester);

    expect(find.text('Sync automatically'), findsWidgets);
    expect(find.text('Sync every'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
  });

  testWidgets('and the interval goes with the loop it schedules', (
    tester,
  ) async {
    // Switched off there is no loop, so how often it would have run is a
    // number about nothing.
    await draw(
      tester,
      withAFile(syncing: false),
      onPoll: (_) {},
      onSyncing: (_) {},
    );
    await openSettings(tester);

    expect(find.text('Sync automatically'), findsWidgets);
    expect(find.text('Sync every'), findsNothing);
  });

  testWidgets('a mirror reading the app\'s library has neither', (
    tester,
  ) async {
    // It opens that file read-only and the server starts no loop over it, so
    // a switch and an interval would both be controls over nothing — and the
    // section says whose library it is instead.
    await draw(tester, withAFile(ownsLibrary: false));
    await openSettings(tester);

    expect(find.text('Sync automatically'), findsNothing);
    expect(find.text('Sync every'), findsNothing);
    expect(find.textContaining('owns this library'), findsOneWidget);
  });

  testWidgets('and absent when there is no file to write into', (tester) async {
    // `--remote` and `--library`: this console is reading somebody else's
    // arrangement, and a control that writes into a file nobody named would
    // act on something nobody chose.
    await draw(tester, reading(null, local: true));
    await openSettings(tester);

    expect(find.text('Sync every'), findsNothing);
    expect(find.text('Generate'), findsNothing);
  });
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
    expect(find.text('Where the data lives'), findsNothing);
    expect(find.text('From the config file'), findsNothing);
    // The way to them, though, is on this page and says what it is — it was a
    // grey strip reading "Console" that had to be clicked to find out.
    expect(find.text('Configuration'), findsOneWidget);
  });

  testWidgets('one press reaches everything that moved', (tester) async {
    await draw(tester, reading(null, local: true));
    await openSettings(tester);

    expect(find.text('The server'), findsOneWidget);
    expect(find.text('Address'), findsOneWidget);
    // Two sections where there was one called "Configuration" — which is the
    // name of the page now, and a section inside a page of the same name
    // reads as a mistake.
    expect(find.text('Where the data lives'), findsOneWidget);
    expect(find.text('From the config file'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    // The library path is edited here, not read: it is the one line of the
    // configuration this window writes.
    expect(find.text('Its own copy'), findsOneWidget);
    expect(find.text('/home/you/config.json'), findsOneWidget);

    // And back again, or the settings are a one-way door.
    await tester.tap(find.text('Close'));
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

  testWidgets('a payload pasted into the field is handed over whole', (
    tester,
  ) async {
    String? paired;
    await draw(tester, reading(null, local: true), onPair: (t) => paired = t);
    await openSettings(tester);

    // Twice over, as Search is: the row's label, and the button beside it.
    expect(find.text('Pair'), findsNWidgets(2));
    await tester.enterText(
      find.widgetWithText(TextField, 'or paste it here and press Enter'),
      '{"server": "https://sync.example"}',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // Whole and unparsed: the window decides nothing about a payload, which
    // is what keeps the master key out of every widget on this page.
    expect(paired, '{"server": "https://sync.example"}');
  });

  testWidgets('a console that has no file to write into offers no Pair', (
    tester,
  ) async {
    // `--remote` and `--library` name no config file, and a console reading
    // somebody else's mirror has no business being handed a master key.
    await draw(tester, reading(null, local: true));
    await openSettings(tester);
    expect(find.text('Pair'), findsNothing);
  });

  testWidgets('the master key is described and never printed', (tester) async {
    await draw(
      tester,
      ConsoleState(
        status: 'Not running — http://127.0.0.1:8100',
        running: false,
        local: true,
        stats: formatStats(const {}, '0'),
        configRows: const [('Master key', 'set')],
      ),
      onPair: (_) {},
    );
    await openSettings(tester);

    expect(find.text('set'), findsOneWidget);
    expect(find.textContaining('AAAA'), findsNothing);
  });

  testWidgets('Browse… asks for the mode the row is in', (tester) async {
    bool? asked;
    await draw(
      tester,
      reading(null, local: true),
      onBrowse: ({required existing}) => asked = existing,
    );
    await openSettings(tester);

    await tester.tap(find.text('Browse…'));
    await tester.pump();
    // "Its own copy" is selected in this state, so the dialog is being opened
    // for a directory this mirror will fill.
    expect(asked, isFalse);
  });
}

void _thisProgram() {
  group('the program keeping itself current', () {
    ConsoleState asAnImage() => ConsoleState(
      status: 'Not running',
      running: false,
      local: true,
      stats: formatStats(const {'items': 3}, '7'),
      configRows: const [('File', '/home/you/config.json')],
      updatable: true,
    );

    testWidgets('an AppImage is offered the update control', (tester) async {
      await draw(tester, asAnImage());
      await openSettings(tester);

      expect(find.text('This program'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);
      // Its own version, so "which one am I running" is answerable in the
      // place where you would go to change it.
      expect(find.text(consoleVersion), findsWidgets);
    });

    testWidgets('and anything else is offered none', (tester) async {
      // A tarball, or `flutter run`. There is no single file to replace, so a
      // button offering to replace one would act on something nobody chose.
      await draw(tester, reading(null, local: true));
      await openSettings(tester);

      expect(find.text('This program'), findsNothing);
      expect(find.text('Check for updates'), findsNothing);
    });
  });
}
