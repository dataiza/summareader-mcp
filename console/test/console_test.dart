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
import 'package:summareader_mcp_console/src/updates.dart';
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
  ValueChanged<bool>? onAutostart,
  void Function(String path, {required bool existing})? onLibrary,
  VoidCallback? onGenerateToken,
  ValueChanged<Release>? onDownloadUpdate,
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
        onLibrary: onLibrary,
        onPoll: onPoll,
        onSyncing: onSyncing,
        onAutostart: onAutostart,
        onDownloadUpdate: onDownloadUpdate,
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
/// Walks to Configuration and, since 0.4.12, to one of its pages.
///
/// It was one column of sections; naming the page a test is about is the cost
/// of that, and it makes the test say where the control lives.
/// Switches pages inside Configuration, which must already be open — the
/// pill in the header is a toggle, so pressing it again leaves.
Future<void> goToPage(WidgetTester tester, String page) async {
  await tester.tap(find.text(page));
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester, [String? page]) async {
  // One press. It was two — a menu bar holding one submenu called "Console",
  // with everything but the library behind that word.
  await tester.tap(find.text('Configuration'));
  await tester.pumpAndSettle();
  if (page != null) {
    await tester.tap(find.text(page));
    await tester.pumpAndSettle();
  }
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
    await openSettings(tester, 'The server');

    expect(find.text('Sync automatically'), findsWidgets);
    expect(find.text('Sync every'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
    // Beside the button, so pressing it changes the page it was pressed on:
    // the toast that says a new one was written is gone six seconds later.
    expect(find.text('not set'), findsOneWidget);
  });

  testWidgets('and the token row says once there is one', (tester) async {
    await draw(
      tester,
      ConsoleState(
        status: 'Not running',
        running: false,
        local: true,
        stats: formatStats(const {'items': 3}, '7'),
        configRows: const [('File', '/home/you/config.json')],
        hasToken: true,
      ),
      onGenerateToken: () {},
    );
    await openSettings(tester, 'The server');

    expect(find.text('set'), findsOneWidget);
    expect(find.text('not set'), findsNothing);
    // Whether, and never what.
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
    await openSettings(tester, 'The server');

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
    await openSettings(tester, 'The server');

    expect(find.text('Sync automatically'), findsNothing);
    expect(find.text('Sync every'), findsNothing);
    expect(find.textContaining('owns this library'), findsOneWidget);
  });

  testWidgets('and absent when there is no file to write into', (tester) async {
    // `--remote` and `--library`: this console is reading somebody else's
    // arrangement, and a control that writes into a file nobody named would
    // act on something nobody chose.
    await draw(tester, reading(null, local: true));
    await openSettings(tester, 'The server');

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

  testWidgets('Configuration is pages, and each holds its own subject', (
    tester,
  ) async {
    // It was one column of five sections, which on a small window is a scroll
    // with the thing you came for somewhere in the middle. The page names are
    // the chooser, so this also asserts that nothing was lost on the way.
    await draw(tester, reading(null, local: true));
    await openSettings(tester);

    // "This program" is offered only to an AppImage — see the group below —
    // and this state is not one, so three pages rather than four.
    for (final page in ['The server', 'Library', 'Sync']) {
      expect(find.text(page), findsWidgets, reason: page);
    }
    expect(find.text('This program'), findsNothing);

    // The server's page: what it runs and where it listens.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Address'), findsOneWidget);

    await goToPage(tester, 'Library');
    expect(find.text('Where the data lives'), findsOneWidget);
    // The library path is edited here, not read: it is the one line of the
    // configuration this window writes.
    expect(find.text('Its own copy'), findsOneWidget);
    expect(find.text('Address'), findsNothing, reason: 'that is another page');

    await goToPage(tester, 'Sync');
    expect(find.text('From the config file'), findsOneWidget);

    // And the library itself is off this screen entirely.
    expect(find.text('Search'), findsNothing);
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
          DateTime.utc(2026, 8, 12, 9, 15),
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
    expect(find.text('2026-08-12 09:13'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('2026-08-11'), findsOneWidget);
    expect(
      find.text('What the borrow checker actually proves'),
      findsOneWidget,
    );

    await openSettings(tester, 'Sync');
    // The token is described, never printed. A window that shows a credential
    // is a window somebody screenshots.
    expect(find.text('set'), findsOneWidget);
  });

  testWidgets('a payload pasted into the field is handed over whole', (
    tester,
  ) async {
    String? paired;
    await draw(tester, reading(null, local: true), onPair: (t) => paired = t);
    await openSettings(tester, 'Sync');

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
    await openSettings(tester, 'Sync');
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
    await openSettings(tester, 'Sync');

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
    await openSettings(tester, 'Library');

    await tester.tap(find.text('Browse…'));
    await tester.pump();
    // "Its own copy" is selected in this state, so the dialog is being opened
    // for a directory this mirror will fill.
    expect(asked, isFalse);
  });

  testWidgets('a mirror on the app\'s library can still choose its own', (
    tester,
  ) async {
    // The way out of that mode: the row was dead there — both segments, the
    // field and Browse… — so the app's library was the last answer the window
    // would ever take.
    (String, bool)? chosen;
    await draw(
      tester,
      ConsoleState(
        status: 'Not running',
        running: false,
        local: false,
        ownsLibrary: false,
        libraryPath: '/home/you/.local/share/sk.dataiza.summareader/x.sqlite',
        stats: formatStats(const {}, '0'),
        configRows: const [('File', '/home/you/config.json')],
      ),
      onLibrary: (path, {required existing}) => chosen = (path, existing),
    );
    await openSettings(tester, 'Library');

    await tester.tap(find.text('Its own copy'));
    await tester.pump();

    expect(chosen?.$2, isFalse);
  });

  testWidgets('and the row says read-only where the choice is made', (
    tester,
  ) async {
    await draw(
      tester,
      ConsoleState(
        status: 'Not running',
        running: false,
        local: false,
        ownsLibrary: false,
        libraryPath: '/home/you/.local/share/sk.dataiza.summareader/x.sqlite',
        stats: formatStats(const {}, '0'),
        configRows: const [('File', '/home/you/config.json')],
      ),
    );
    await openSettings(tester, 'Library');

    expect(find.textContaining('Opened read-only'), findsOneWidget);
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
      await openSettings(tester, 'This program');

      expect(find.text('This program'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);
      // Its own version, so "which one am I running" is answerable in the
      // place where you would go to change it.
      expect(find.text(consoleVersion), findsWidgets);
    });

    testWidgets('a found release is offered, not installed', (tester) async {
      // Replacing the program somebody is running is the one control on this
      // page that changes this program, and it used to happen because they
      // pressed "check".
      Release? asked;
      await draw(
        tester,
        ConsoleState(
          status: 'Not running',
          running: false,
          local: true,
          stats: formatStats(const {'items': 3}, '7'),
          configRows: const [('File', '/home/you/config.json')],
          updatable: true,
          updateOffer: (
            version: '9.9.9',
            image: Uri.parse('https://example.invalid/x.AppImage'),
          ),
          updateSaid: 'Downloading… 42%',
        ),
        onDownloadUpdate: (release) => asked = release,
      );
      await openSettings(tester, 'This program');

      expect(find.text('9.9.9 is available'), findsOneWidget);
      expect(find.text('Downloading… 42%'), findsOneWidget);
      // Nothing to restart into until something is in place.
      expect(find.text('Restart now'), findsNothing);

      await tester.ensureVisible(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(asked?.version, '9.9.9');
    });

    testWidgets('and once it is in place, a way into it', (tester) async {
      await draw(
        tester,
        ConsoleState(
          status: 'Not running',
          running: false,
          local: true,
          stats: formatStats(const {'items': 3}, '7'),
          configRows: const [('File', '/home/you/config.json')],
          updatable: true,
          updateSaid: '9.9.9 is in place — restart to use it.',
          updateInstalled: '/home/you/Applications/X-9.9.9.AppImage',
        ),
      );
      await openSettings(tester, 'This program');

      expect(find.text('Restart now'), findsOneWidget);
    });

    testWidgets('the mirror can be told to start with the window', (
      tester,
    ) async {
      bool? asked;
      await draw(
        tester,
        ConsoleState(
          status: 'Not running',
          running: false,
          local: true,
          stats: formatStats(const {'items': 3}, '7'),
          configRows: const [('File', '/home/you/config.json')],
        ),
        onAutostart: (on) => asked = on,
      );
      // A tarball has no image to replace, so the page exists here for this
      // switch alone — which is the case worth asserting, since the page used
      // to be offered for the update control or not at all.
      await openSettings(tester, 'This program');

      expect(find.text('Check for updates'), findsNothing);
      expect(find.text('Start the mirror when this opens'), findsWidgets);

      await tester.tap(find.byType(ArSwitch));
      await tester.pumpAndSettle();
      expect(asked, isTrue);
    });

    testWidgets('and anything else is offered none', (tester) async {
      // A tarball, or `flutter run`. There is no single file to replace, so a
      // button offering to replace one would act on something nobody chose —
      // and since Configuration is pages, the page itself is not offered
      // either, rather than opening on an explanation of why it is empty.
      await draw(tester, reading(null, local: true));
      await openSettings(tester);

      expect(find.text('This program'), findsNothing);
      expect(find.text('Check for updates'), findsNothing);
    });
  });
}
