/// The window, and the one class in it worth looking at.
///
/// [ConsoleView] is a function of [ConsoleState] and nothing else: no store,
/// no processes, no timers. That is what lets the golden test draw the whole
/// console from a seeded library with no display and no server, and it is the
/// same discipline the Tk window followed for the opposite reason — there,
/// because a window could not be tested at all.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:summareader_ui/summareader_ui.dart';

import 'addresses.dart';
import 'updates.dart';
import 'library.dart';
import 'version.dart';

/// Everything drawn, at one moment.
class ConsoleState {
  const ConsoleState({
    required this.status,
    required this.running,
    required this.stats,
    required this.configRows,
    this.libraryPath = '',
    this.ownsLibrary = true,
    this.host = '127.0.0.1',
    this.port = 8100,
    this.hosts = const [],
    this.note,
    this.results = const [],
    this.local = true,
    this.atLogin,
    this.message = '',
    this.busy = false,
    this.updateOffer,
    this.updateSaid,
    this.updateInstalled,
    this.syncing = true,
    this.autostart = false,
    this.hasToken = false,
    this.pollSeconds = 300,
    this.updatable = false,
  });

  /// "Running on http://…" or "Not running — …", already worded.
  final String status;
  final bool running;

  /// Why half of this is off, when it is. A sentence rather than a greyed-out
  /// button with no explanation beside it.
  final String? note;

  /// Where the server listens, and what the chooser offers instead — already
  /// ordered, so the view has no opinion about which interface matters.
  final String host;
  final int port;
  final List<LanAddr> hosts;
  final List<(String, String)> stats;
  final List<(String, String)> configRows;

  /// Whether the mirror pulls on its own, and how often when it does.
  final bool syncing;
  final int pollSeconds;

  /// Whether running this console is by itself enough to start the mirror.
  final bool autostart;

  /// Whether the port has a credential guarding it. Whether, and never what:
  /// a window that shows a token is a window somebody screenshots.
  final bool hasToken;

  /// A newer release, found and not yet accepted. Replacing the program
  /// somebody is running is not something to do because they pressed "check".
  final Release? updateOffer;

  /// Where the new version is, once it is in place. The old one is still the
  /// process on screen, so the honest end of an update is a button that
  /// starts the new one.
  final String? updateInstalled;

  /// What the check or the download is doing, or what it did. A line rather
  /// than a message that fades: a download is a minute long, and the sentence
  /// about restarting is worth still being there afterwards.
  final String? updateSaid;

  /// Whether this console can update and register itself — true only when it
  /// is running as an AppImage, which is the one form that is a single file it
  /// owns. A tarball or a `flutter run` shows neither control, because both
  /// would act on something nobody chose.
  final bool updatable;

  /// The library on screen, and whether this mirror fills it or merely reads
  /// one somebody else fills.
  final String libraryPath;
  final bool ownsLibrary;
  final List<Item> results;

  /// Whether this console is the machine that holds the library. Start, Stop
  /// and Pull exist only here.
  final bool local;

  /// Null where there is no systemd to write a unit into — absent rather than
  /// greyed out, because a control that cannot work anywhere on this machine
  /// is worse than no control at all.
  final bool? atLogin;
  final String message;

  /// One action at a time. A second Pull while the first is running is two
  /// pulls, and a second Start is a server that fails to bind.
  final bool busy;
}

class ConsoleView extends StatefulWidget {
  const ConsoleView({
    super.key,
    required this.state,
    required this.query,
    this.onToggle,
    this.onPull,
    this.onSearch,
    this.onAtLogin,
    this.onBind,
    this.onPort,
    this.onLibrary,
    this.onPair,
    this.onPoll,
    this.onSyncing,
    this.onAutostart,
    this.onGenerateToken,
    this.onCheckUpdates,
    this.onDownloadUpdate,
    this.onDismissUpdate,
    this.onRestart,
    this.onBrowse,
  });

  final ConsoleState state;
  final TextEditingController query;

  /// One button: Start when it is stopped, Stop when it is running. Which of
  /// the two it does is the state's business, not the caller's.
  final VoidCallback? onToggle;
  final VoidCallback? onPull;
  final ValueChanged<String>? onSearch;
  final ValueChanged<bool>? onAtLogin;
  final ValueChanged<String>? onBind;
  final ValueChanged<String>? onPort;

  /// A path, and whether this mirror is to own the library there.
  final void Function(String path, {required bool existing})? onLibrary;

  /// Open a directory picker for one of the two modes, and do with the answer
  /// whatever [onLibrary] would have done with a typed path. Null where there
  /// is nothing to choose, for the same reasons [onLibrary] is.
  final void Function({required bool existing})? onBrowse;

  /// A whole pairing payload, from the clipboard or from the field beside it.
  /// Null where there is no config file to write into — a `--remote` or
  /// `--library` console is reading somebody else's arrangement.
  final ValueChanged<String>? onPair;

  /// Seconds between pulls, typed. Null for the same reason [onPair] is —
  /// there is no file to write it into.
  final ValueChanged<String>? onPoll;

  /// Turn the pulling loop on and off. Null alongside [onPoll], and also when
  /// this mirror reads the app's own library — there is no loop to switch.
  final ValueChanged<bool>? onSyncing;

  /// Start the mirror whenever this console runs. Null where this console has
  /// no mirror to start — somebody else's over a port, the app's own library,
  /// or a configuration that is not finished.
  final ValueChanged<bool>? onAutostart;

  /// Mint a bearer token and write it. Null where there is no config file.
  final VoidCallback? onGenerateToken;

  /// Accept the offered release, and put the offer away again.
  final ValueChanged<Release>? onDownloadUpdate;
  final VoidCallback? onDismissUpdate;

  /// Start the new version and leave. Only offered once there is one.
  final VoidCallback? onRestart;

  /// Asked for by a press. Absent unless this is an AppImage — see
  /// [ConsoleState.updatable].
  final VoidCallback? onCheckUpdates;

  @override
  State<ConsoleView> createState() => _ConsoleViewState();
}

/// The pages Configuration is divided into.
///
/// It was one column of five sections, which on a small window is a scroll
/// with the thing you came for somewhere in the middle of it. One subject per
/// page, named, the way the app spells the same idea.
enum ConfigPage {
  server('The server'),
  library('Library'),
  sync('Sync'),
  program('This program');

  const ConfigPage(this.title);
  final String title;
}

class _ConsoleViewState extends State<ConsoleView> {
  /// Which of the two screens is on. A field rather than a route, because
  /// the state above rebuilds this window every two seconds: a pushed route
  /// would keep the console it was pushed with, and Settings would sit there
  /// with a Start button that never became Stop.
  bool _settings = false;

  ConfigPage _page = ConfigPage.server;

  @override
  Widget build(BuildContext context) => _screen(
    _settings
        ? [
            _header(),
            if (widget.state.note case final note?) ...[
              const SizedBox(height: Ar.space4),
              _note(note),
            ],
            const SizedBox(height: Ar.space4),
            _pages(),
            const SizedBox(height: Ar.space4),
            // A page that stopped existing — "This program" where there is
            // neither an image to replace nor a mirror to start — must not
            // leave the window blank.
            ...switch (_page == ConfigPage.program && !_thisProgramHasAnything
                ? ConfigPage.server
                : _page) {
              ConfigPage.server => [
                _server(),
                if (widget.state.local) _address(),
              ],
              ConfigPage.library => [_whereTheDataLives()],
              ConfigPage.sync => [_fromTheConfigFile()],
              ConfigPage.program => [
                if (_thisProgramHasAnything) _thisProgram(),
              ],
            },
          ]
        : [
            _header(),
            if (widget.state.note case final note?) ...[
              const SizedBox(height: Ar.space4),
              _note(note),
            ],
            const SizedBox(height: Ar.space6),
            _library(),
            _search(context),
          ],
  );

  /// The page chooser: one pill per subject, the way the header spells
  /// Configuration itself.
  Widget _pages() => Wrap(
    spacing: Ar.space2,
    runSpacing: Ar.space2,
    children: [
      // Only the pages that have something on them: a tarball with no mirror
      // of its own has neither control below, so "This program" would open on
      // an explanation of why it is empty, which is worse than not being
      // offered.
      for (final page in ConfigPage.values)
        if (page != ConfigPage.program || _thisProgramHasAnything)
          Segment(
            label: page.title,
            selected: _page == page,
            onTap: () => setState(() => _page = page),
          ),
    ],
  );

  /// The sections, whichever screen they belong to.
  ///
  /// Both are drawn by this, so the window does not change shape between them
  /// — the header, and the Configuration pill in it, are the only fixed part.
  Widget _screen(List<Widget> sections) => Scaffold(
    backgroundColor: Ar.bg,
    body: Stack(
      children: [
        SafeArea(
          // Stretched, so the menu is a bar across the top rather than a
          // lozenge floating in the middle of it.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    // The reading measure the app uses for its own settings
                    // pane. Full-width rows on a maximised window put the
                    // label and the control at opposite ends of a metre of
                    // desk.
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        Ar.space6,
                        Ar.space6,
                        Ar.space6,
                        Ar.space8,
                      ),
                      children: sections,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.state.message.isNotEmpty) ArToast(widget.state.message),
      ],
    ),
  );

  /// The top menu.
  ///
  /// The server, the address and the configuration used to sit between the
  /// library and the search box, which are the two things anybody opens this
  /// window for — so the window it was worth keeping open was the one you had
  /// to scroll past the settings to use. They are a screen of their own now,
  /// and this is how it is reached. The entry for the screen already on is
  /// dead rather than missing, so the menu reads the same from both.
  // ---- the pieces ------------------------------------------------------

  Widget _header() {
    const title = 'SummaReader MCP';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Eyebrow('Model Context Protocol'),
              const SizedBox(height: Ar.space1),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: Ar.headingStyle(28, forText: title),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Small and quiet, but present, exactly as the app does it:
                  // "which one am I running" should not need a menu, and this
                  // window has no About to put it in.
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      consoleVersion,
                      style: Ar.bodyStyle(12, color: Ar.dim(0.45)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Ar.space1),
              Text(
                widget.state.status,
                style: Ar.bodyStyle(13.5, color: Ar.dim(0.6)),
              ),
            ],
          ),
        ),
        // The status light. Green for running is the whole reason somebody
        // opens this window, so it is the one thing readable across a room.
        Padding(
          padding: const EdgeInsets.only(top: Ar.space3),
          child: Tag(
            label: widget.state.running ? 'running' : 'stopped',
            background: widget.state.running ? Ar.accent2200 : Ar.neutral200,
            foreground: widget.state.running ? Ar.accent2800 : Ar.dim(0.6),
            fontSize: 12.5,
          ),
        ),
        const SizedBox(width: Ar.space3),
        // Here rather than in a menu bar across the top. That bar held one
        // submenu, labelled "Console", and everything but the library was
        // behind that word — a strip of grey somebody has to think to click,
        // which is exactly what happened. The app spells this control as a
        // pill: label, Icons.tune, and a Close beside the title to come back.
        Padding(
          padding: const EdgeInsets.only(top: Ar.space2),
          child: _settings
              ? PillButton(
                  label: 'Close',
                  icon: Icons.arrow_back,
                  onTap: () => setState(() => _settings = false),
                )
              : PillButton(
                  label: 'Configuration',
                  icon: Icons.tune,
                  onTap: () => setState(() => _settings = true),
                ),
        ),
      ],
    );
  }

  Widget _note(String note) => Container(
    padding: const EdgeInsets.all(Ar.space3),
    decoration: BoxDecoration(
      color: Ar.accent100,
      borderRadius: BorderRadius.circular(Ar.radiusMd),
      border: Border.all(color: Ar.accent300),
    ),
    child: Text(
      note,
      style: Ar.bodyStyle(13, color: Ar.accent800, height: 1.5),
    ),
  );

  Widget _library() => _section(
    'Library',
    'What this machine holds, and how the syncing has been going.',
    _card([
      Wrap(
        spacing: Ar.space6,
        runSpacing: Ar.space4,
        children: [
          for (final (label, value) in widget.state.stats)
            SizedBox(
              // A fixed measure, so the numbers line up in a grid instead of
              // reflowing every two seconds as the values change width.
              width: 196,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // "3 hours ago" is a value in this grid as much as "1284"
                  // is, and set at the size of a number it wraps onto three
                  // lines and drags the whole row down with it.
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ar.headingStyle(
                      value.length > 6 ? 16 : 21,
                      forText: value,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(label, style: Ar.bodyStyle(12, color: Ar.dim(0.55))),
                ],
              ),
            ),
        ],
      ),
    ]),
  );

  Widget _server() => _section(
    'The server',
    widget.state.local
        ? 'The mirror runs as its own process, started with exactly the '
              'command the systemd unit holds.'
        : widget.state.ownsLibrary
        ? 'Somewhere else — this console is reading, not running anything.'
        : 'The app on this machine owns this library and fills it. A mirror '
              'reading one opens it read-only and never pulls, so there is '
              'nothing here to start or to schedule.',
    _card([
      Wrap(
        spacing: Ar.space2,
        runSpacing: Ar.space2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // One button rather than two: with a Start and a Stop side by side
          // one of them is always dead, for no reason a reader can see. The
          // label says what pressing it will do — including when a unit owns
          // the server and it is systemctl doing it.
          PrimaryButton(
            label: widget.state.running ? 'Stop' : 'Start',
            icon: widget.state.running
                ? Icons.stop_rounded
                : Icons.play_arrow_rounded,
            onTap: widget.state.local && !widget.state.busy
                ? widget.onToggle
                : null,
          ),
          // "Sync now", not "Pull now", though pulling is all it does. The
          // app's button says Sync now and this is the same errand from the
          // other end; two words for one action is a difference somebody has
          // to learn for nothing.
          PillButton(
            label: 'Sync now',
            icon: Icons.sync_rounded,
            height: 40,
            onTap: widget.state.local && !widget.state.busy
                ? widget.onPull
                : null,
          ),
        ],
      ),
      if (widget.onSyncing != null)
        _row(
          'Sync automatically',
          ArSwitch(
            label: 'Sync automatically',
            value: widget.state.syncing,
            onChanged: widget.state.busy ? null : widget.onSyncing,
          ),
          hint:
              'Off is a mirror that holds what it already has and asks for '
              'nothing. Sync now still works, and so does the command line.',
        ),
      if (widget.onPoll != null && widget.state.syncing)
        _row(
          'Sync every',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 110,
                child: _NumberField(
                  value: '${widget.state.pollSeconds}',
                  onSubmitted: widget.onPoll,
                ),
              ),
              const SizedBox(width: Ar.space2),
              Text('seconds', style: Ar.bodyStyle(13, color: Ar.dim(0.75))),
            ],
          ),
          hint:
              'What the mirror does on its own between presses of Sync now. '
              'Takes effect the next time it starts.',
        ),
      if (widget.state.atLogin case final at?)
        _row(
          'Start at login',
          ArSwitch(
            label: 'Start at login',
            value: at,
            onChanged: widget.state.busy ? null : widget.onAtLogin,
          ),
          hint:
              'Writes a user service, so the mirror comes back after a '
              'reboot and outlives this window.',
        ),
    ]),
  );

  Widget _address() => _section(
    'Address',
    'Where the mirror listens. Changing either restarts it — a listening '
        'socket cannot be moved — and rewrites the unit when there is one.',
    _card([
      _row(
        'Bind address',
        Wrap(
          spacing: 6,
          runSpacing: 6,
          alignment: WrapAlignment.end,
          children: [
            for (final candidate in widget.state.hosts)
              Segment(
                label: candidate.toString(),
                selected: candidate.ip == widget.state.host,
                onTap: widget.onBind == null || widget.state.busy
                    ? null
                    : () => widget.onBind!(candidate.ip),
              ),
          ],
        ),
        hint:
            'Loopback and 0.0.0.0 are the two decisions; the rest are '
            'addresses this machine answers on. Anything wider than loopback '
            'needs a bearer token — this port serves the whole library in '
            'plaintext.',
      ),
      if (widget.onGenerateToken != null)
        _row(
          'Bearer token',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Whether there is one, beside the button that makes one. The
              // toast says a new token was written and then goes away, which
              // leaves a row that looks exactly as it did before it was
              // pressed; this is the half that stays.
              Tag(
                label: widget.state.hasToken ? 'set' : 'not set',
                background: widget.state.hasToken
                    ? Ar.accent2200
                    : Ar.neutral200,
                foreground: widget.state.hasToken ? Ar.accent2800 : Ar.dim(0.6),
                fontSize: 12.5,
              ),
              const SizedBox(width: Ar.space3),
              PillButton(
                label: 'Generate',
                icon: Icons.key_outlined,
                height: 38,
                onTap: widget.state.busy ? null : widget.onGenerateToken,
              ),
            ],
          ),
          hint:
              'Makes a new one, writes it to the config file and puts it on '
              'the clipboard — the one moment it is readable, because a '
              'client has to be given it. Paste it somewhere before you copy '
              'anything else. Any client holding the old one stops working.',
        ),
      _row(
        'Port',
        SizedBox(
          width: 110,
          child: _NumberField(
            value: '${widget.state.port}',
            onSubmitted: widget.onPort,
          ),
        ),
      ),
    ]),
  );

  /// Where the library is — the one thing on this page that is editable.
  ///
  /// Split out of a section that was called "Configuration", which is now the
  /// name of the page it sits on. A section inside a page of the same name
  /// reads as a mistake, and this half is also the only half somebody can
  /// change.
  Widget _whereTheDataLives() => _section(
    'Where the data lives',
    'The decrypted library, and nothing else. It is the most complete copy of '
        'your reading that exists anywhere, because a mirror runs no '
        'retention — so it lives with your data rather than in a cache '
        'directory, whatever it is still spelled.',
    _card([
      _row(
        'Library',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Segment(
                  label: 'Its own copy',
                  selected: widget.state.ownsLibrary,
                  onTap: widget.state.busy
                      ? null
                      : () => widget.onLibrary?.call(
                          widget.state.libraryPath,
                          existing: false,
                        ),
                ),
                Segment(
                  label: 'An existing library',
                  selected: !widget.state.ownsLibrary,
                  onTap: widget.state.busy
                      ? null
                      : () => widget.onLibrary?.call(
                          widget.state.libraryPath,
                          existing: true,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // What the chosen mode means, next to the buttons that choose it.
            // The long version is the hint beside this row, which is where
            // somebody looks second; read-only is the fact worth having
            // where the decision is made.
            Text(
              widget.state.ownsLibrary
                  ? 'This mirror fills this directory by pulling and '
                        'decrypting. It is the only thing that writes here.'
                  : 'Opened read-only. Nothing here writes to the app\'s '
                        'library, and nothing pulls into it.',
              style: Ar.bodyStyle(12.5, color: Ar.dim(0.6), height: 1.5),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _PathField(
                    key: ValueKey('library:${widget.state.libraryPath}'),
                    path: widget.state.libraryPath,
                    onSubmitted: widget.onLibrary == null || widget.state.busy
                        ? null
                        : (value) => widget.onLibrary!(
                            value,
                            existing: !widget.state.ownsLibrary,
                          ),
                  ),
                ),
                const SizedBox(width: Ar.space2),
                // Beside the field rather than instead of it: a path can still
                // be typed or pasted, and a machine reached over ssh has no
                // dialog to open at all.
                PillButton(
                  label: 'Browse…',
                  icon: Icons.folder_open_rounded,
                  height: 38,
                  onTap: widget.onBrowse == null || widget.state.busy
                      ? null
                      : () => widget.onBrowse!(
                          existing: !widget.state.ownsLibrary,
                        ),
                ),
              ],
            ),
          ],
        ),
        // The second half of this used to say only what the mode means, and
        // left somebody in a file dialog with no idea what they were looking
        // for. The app keeps its library in an application support directory
        // nobody visits on purpose, so the answer is worth spelling out.
        hint: widget.state.ownsLibrary
            ? 'This mirror fills it, by pulling and decrypting. The path is '
                  'the directory it lives in; the library itself is made on '
                  'the first pull.'
            : 'Somebody else fills it — the app, on this machine — and it is '
                  'opened read-only. Needs no server, token or master key, '
                  'and nothing here will pull into it.\n\n'
                  'Browse to the app\'s data directory — on Linux that is '
                  '~/.local/share/sk.dataiza.summareader, or '
                  '…summareader.premium for Premium — and the summareader.sqlite '
                  'inside it is found for you. Typing that directory works too.',
      ),
    ]),
  );

  /// What the config file says, read and not edited.
  ///
  /// A window that edits somebody's master key is a window that can lose it,
  /// so these are shown and never written from here. The file itself is named
  /// in the first row, which is where to go and change them.
  Widget _fromTheConfigFile() => _section(
    'From the config file',
    'Read here, edited there — except pairing, which writes the server, the '
        'token and the key together in one go. The master key is never shown '
        'at all.',
    _card([
      for (final (label, value) in widget.state.configRows)
        _row(
          label,
          // Selectable, because the whole point of showing a path is that
          // somebody is about to open it somewhere else.
          SelectableText(
            value,
            style: Ar.bodyStyle(13, color: Ar.dim(0.75)),
            maxLines: 1,
          ),
        ),
      if (widget.onPair != null) _pair(),
    ]),
  );

  /// The one thing on this page that writes a credential.
  ///
  /// Whole payloads only: the button takes what the app's Copy MCP config put
  /// on the clipboard and the field takes the same text when the clipboard is
  /// not the route — a phone reading the code aloud, a payload out of a
  /// message. Either way it is accepted or refused entire, which is what
  /// makes writing a master key from a window acceptable when a field holding
  /// one would not be.
  /// The version, and the way to a newer one.
  ///
  /// Pressed, never automatic and never on launch: a window that asks the
  /// network about itself before anybody said so is a window nobody chose.

  /// Whether there is anything to put on the last page: an image this program
  /// can replace, or a mirror it can be told to start with.
  bool get _thisProgramHasAnything =>
      widget.state.updatable || widget.onAutostart != null;

  /// The program itself, as opposed to the library it opens or the server it
  /// supervises.
  Widget _thisProgram() => _section(
    'This program',
    widget.state.updatable
        ? 'An AppImage is one file you downloaded, with no package manager '
              'behind it, so keeping itself current is something it has to do '
              'for itself.'
        : 'What this console does when it runs, as opposed to the library it '
              'opens or the server it supervises.',
    _card([
      if (widget.onAutostart != null)
        _row(
          'Start the mirror when this opens',
          ArSwitch(
            label: 'Start the mirror when this opens',
            value: widget.state.autostart,
            onChanged: widget.state.busy ? null : widget.onAutostart,
          ),
          hint:
              'Opening the window is then the whole of it. Off is the window '
              'waiting to be told, which is what it has always done. It needs '
              'a bind address, a port and a bearer token before it will start '
              'anything on its own; with one of them missing nothing starts '
              'and the window says which.',
        ),
      if (widget.state.updatable) _updates(),
      // Found, and waiting to be told to go ahead.
      if (widget.state.updateOffer case final offer?)
        _row(
          '${offer.version} is available',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PillButton(
                label: 'Download',
                icon: Icons.download_outlined,
                height: 34,
                onTap: () => widget.onDownloadUpdate?.call(offer),
              ),
              const SizedBox(width: Ar.space2),
              PillButton(
                label: 'Cancel',
                height: 34,
                onTap: widget.onDismissUpdate,
              ),
            ],
          ),
          hint:
              'Downloading replaces this AppImage where it sits. The copy you '
              'have open keeps running; the new version starts next time.',
        ),
      // What it is doing, or what it did.
      if (widget.state.updateSaid case final said?)
        _row(
          said,
          widget.state.updateInstalled == null
              ? const SizedBox.shrink()
              : PillButton(
                  label: 'Restart now',
                  icon: Icons.restart_alt,
                  height: 34,
                  onTap: widget.onRestart,
                ),
        ),
    ]),
  );

  Widget _updates() => _row(
    'This console',
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(consoleVersion, style: Ar.bodyStyle(13, color: Ar.dim(0.75))),
        const SizedBox(width: Ar.space3),
        PillButton(
          label: 'Check for updates',
          icon: Icons.download_outlined,
          onTap: widget.state.busy ? null : widget.onCheckUpdates,
        ),
      ],
    ),
    hint:
        'Asks GitHub for the newest release and replaces this AppImage with '
        'it. Nothing is checked until you press it.',
  );

  Widget _pair() => _row(
    'Pair',
    Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        PrimaryButton(
          label: 'Pair',
          icon: Icons.content_paste_rounded,
          onTap: widget.state.busy
              ? null
              : () async {
                  final board = await Clipboard.getData(Clipboard.kTextPlain);
                  widget.onPair!(board?.text ?? '');
                },
        ),
        const SizedBox(height: 8),
        _PathField(
          key: const ValueKey('pair'),
          path: '',
          hint: 'or paste it here and press Enter',
          onSubmitted: widget.state.busy ? null : widget.onPair,
        ),
      ],
    ),
    hint:
        'In the app: Settings → Sync → Add another device → Copy MCP config. '
        'The pairing code itself works too. Nothing of it is shown here, and '
        'the key least of all.',
  );

  /// What can go in the box, spelled out under it.
  ///
  /// Six fields and two shapes of date is more than a placeholder can hold,
  /// and a query language nobody can see the whole of is one people use two
  /// fields of. Words with no field search everything; a field narrows.
  Widget _fields() => Wrap(
    spacing: Ar.space4,
    runSpacing: Ar.space1,
    children: [
      for (final (name, what) in const [
        ('source:', 'the feed, as a word starts'),
        ('title:', 'the title only'),
        ('tag:', 'a tag on it or on its feed'),
        ('since: until:', '7d, 3h, 3w, or 2026-08-01'),
        ('read:', 'when it was read, same shapes'),
        ('unread: summarized:', 'yes or no'),
      ])
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: '$name ',
                style: Ar.bodyStyle(12, weight: FontWeight.w600),
              ),
              TextSpan(
                text: what,
                style: Ar.bodyStyle(12, color: Ar.dim(0.6)),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _search(BuildContext context) => _section(
    'Search',
    'Over everything in the mirror — titles, sources, summaries and the '
        'article text. The same words, and the same fields, as the terminal '
        'interface and the command line.',
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ArField(
                controller: widget.query,
                // The example is the documentation somebody actually reads.
                // An empty box that takes a query language and says "a word"
                // is a box nobody types a field into.
                hint: 'rust source:"The Morning Paper" since:7d unread:yes',
                icon: Icons.search_rounded,
                onSubmitted: widget.onSearch,
              ),
            ),
            const SizedBox(width: Ar.space2),
            PillButton(
              label: 'Search',
              height: 38,
              onTap: widget.onSearch == null
                  ? null
                  : () => widget.onSearch!(widget.query.text),
            ),
          ],
        ),
        const SizedBox(height: Ar.space2),
        _fields(),
        const SizedBox(height: Ar.space3),
        if (widget.state.results.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Ar.space4),
            child: Text(
              'Nothing matching.',
              style: Ar.bodyStyle(13.5, color: Ar.dim(0.5)),
            ),
          )
        else
          for (final item in widget.state.results)
            Padding(
              padding: const EdgeInsets.only(bottom: Ar.space2),
              child: SurfaceCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: Ar.space4,
                  vertical: Ar.space3,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        item.when,
                        style: Ar.bodyStyle(12.5, color: Ar.dim(0.55)),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: Text(
                        item.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ar.bodyStyle(12.5, color: Ar.dim(0.7)),
                      ),
                    ),
                    const SizedBox(width: Ar.space3),
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Ar.bodyStyle(13.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    ),
  );

  // ---- the shapes the app's own settings pane is made of ---------------

  /// A section, with its own heading unless the page is already called that.
  ///
  /// Configuration is pages now, and a page called "Library" holding a
  /// section called "Library" says it twice — which also made "is this
  /// control on screen" ambiguous to anything reading the window, tests
  /// included.
  Widget _section(String title, String blurb, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 30),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_settings || title != _page.title) ...[
          Text(title, style: Ar.headingStyle(19, forText: title)),
          const SizedBox(height: 4),
        ],
        Text(blurb, style: Ar.bodyStyle(13.5, color: Ar.dim(0.6))),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );

  Widget _card(List<Widget> rows) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Ar.surface,
      borderRadius: BorderRadius.circular(Ar.radiusMd),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i != rows.length - 1) const SizedBox(height: 16),
        ],
      ],
    ),
  );

  /// A setting: what it is called on the left, what it says on the right.
  Widget _row(String label, Widget control, {String? hint}) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Ar.bodyStyle(14)),
            if (hint != null)
              Text(hint, style: Ar.bodyStyle(12, color: Ar.dim(0.6))),
          ],
        ),
      ),
      Flexible(
        child: Align(alignment: Alignment.centerRight, child: control),
      ),
    ],
  );
}

/// A path, in a field wide enough to read one — and the box a pairing payload
/// is pasted into, which wants the same thing of a field and nothing more.
///
/// Same reason as the port field below: rebuilt from state twice a second, a
/// controller loses the caret mid-word.
class _PathField extends StatefulWidget {
  const _PathField({
    super.key,
    required this.path,
    this.hint,
    this.onSubmitted,
  });

  final String path;
  final String? hint;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final _controller = TextEditingController(text: widget.path);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArField(
    controller: _controller,
    hint: widget.hint,
    background: Ar.neutral100,
    onSubmitted: widget.onSubmitted,
  );
}

/// A number — a port, an interval — in a field that keeps its own text.
///
/// Its own widget because a controller rebuilt on every poll loses the caret
/// twice a second, which is a field nobody can type four digits into.
class _NumberField extends StatefulWidget {
  const _NumberField({required this.value, this.onSubmitted});

  final String value;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArField(
    controller: _controller,
    background: Ar.neutral100,
    onSubmitted: widget.onSubmitted,
  );
}

/// A message that shows for a moment and then is not in the way any more.
///
/// The Tk window left its last line on screen for ever, which after a while
/// reads as the current state rather than as what happened once.
class Fading {
  Fading(this._show);

  final void Function(String) _show;
  Timer? _timer;

  void say(String message) {
    _show(message);
    _timer?.cancel();
    if (message.isEmpty) return;
    _timer = Timer(const Duration(seconds: 6), () => _show(''));
  }

  void cancel() => _timer?.cancel();
}
