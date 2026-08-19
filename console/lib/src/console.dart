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
import 'package:summareader_ui/summareader_ui.dart';

import 'addresses.dart';
import 'library.dart';

/// Everything drawn, at one moment.
class ConsoleState {
  const ConsoleState({
    required this.status,
    required this.running,
    required this.stats,
    required this.configRows,
    this.host = '127.0.0.1',
    this.port = 8100,
    this.hosts = const [],
    this.note,
    this.results = const [],
    this.local = true,
    this.atLogin,
    this.message = '',
    this.busy = false,
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

class ConsoleView extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ar.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                // The reading measure the app uses for its own settings pane.
                // Full-width rows on a maximised window put the label and the
                // control at opposite ends of a metre of desk.
                constraints: const BoxConstraints(maxWidth: 980),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Ar.space6,
                    Ar.space6,
                    Ar.space6,
                    Ar.space8,
                  ),
                  children: [
                    _header(),
                    if (state.note case final note?) ...[
                      const SizedBox(height: Ar.space4),
                      _note(note),
                    ],
                    const SizedBox(height: Ar.space6),
                    _library(),
                    _server(),
                    if (state.local) _address(),
                    _configuration(),
                    _search(context),
                  ],
                ),
              ),
            ),
          ),
          if (state.message.isNotEmpty) ArToast(state.message),
        ],
      ),
    );
  }

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
              Text(title, style: Ar.headingStyle(28, forText: title)),
              const SizedBox(height: Ar.space1),
              Text(state.status, style: Ar.bodyStyle(13.5, color: Ar.dim(0.6))),
            ],
          ),
        ),
        // The status light. Green for running is the whole reason somebody
        // opens this window, so it is the one thing readable across a room.
        Padding(
          padding: const EdgeInsets.only(top: Ar.space3),
          child: Tag(
            label: state.running ? 'running' : 'stopped',
            background: state.running ? Ar.accent2200 : Ar.neutral200,
            foreground: state.running ? Ar.accent2800 : Ar.dim(0.6),
            fontSize: 12.5,
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
          for (final (label, value) in state.stats)
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
    state.local
        ? 'The mirror runs as its own process, started with exactly the '
              'command the systemd unit holds.'
        : 'Somewhere else — this console is reading, not running anything.',
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
            label: state.running ? 'Stop' : 'Start',
            icon: state.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
            onTap: state.local && !state.busy ? onToggle : null,
          ),
          // "Sync now", not "Pull now", though pulling is all it does. The
          // app's button says Sync now and this is the same errand from the
          // other end; two words for one action is a difference somebody has
          // to learn for nothing.
          PillButton(
            label: 'Sync now',
            icon: Icons.sync_rounded,
            height: 40,
            onTap: state.local && !state.busy ? onPull : null,
          ),
        ],
      ),
      if (state.atLogin case final at?)
        _row(
          'Start at login',
          ArSwitch(
            label: 'Start at login',
            value: at,
            onChanged: state.busy ? null : onAtLogin,
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
            for (final candidate in state.hosts)
              Segment(
                label: candidate.toString(),
                selected: candidate.ip == state.host,
                onTap: onBind == null || state.busy
                    ? null
                    : () => onBind!(candidate.ip),
              ),
          ],
        ),
        hint:
            'Loopback and 0.0.0.0 are the two decisions; the rest are '
            'addresses this machine answers on. Anything wider than loopback '
            'needs a bearer token — this port serves the whole library in '
            'plaintext.',
      ),
      _row(
        'Port',
        SizedBox(
          width: 110,
          child: _PortField(port: '${state.port}', onSubmitted: onPort),
        ),
      ),
    ]),
  );

  Widget _configuration() => _section(
    'Configuration',
    'Read-only. Editing JSON by hand is the other step only a terminal '
        'could do, and knowing which file to edit is most of it.',
    _card([
      for (final (label, value) in state.configRows)
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
    ]),
  );

  Widget _search(BuildContext context) => _section(
    'Search',
    'Over everything in the mirror — titles, sources, summaries and the '
        'article text. The same match the command line makes.',
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ArField(
                controller: query,
                hint: 'a word, as it starts',
                icon: Icons.search_rounded,
                onSubmitted: onSearch,
              ),
            ),
            const SizedBox(width: Ar.space2),
            PillButton(
              label: 'Search',
              height: 38,
              onTap: onSearch == null ? null : () => onSearch!(query.text),
            ),
          ],
        ),
        const SizedBox(height: Ar.space3),
        if (state.results.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Ar.space4),
            child: Text(
              'Nothing matching.',
              style: Ar.bodyStyle(13.5, color: Ar.dim(0.5)),
            ),
          )
        else
          for (final item in state.results)
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

  Widget _section(String title, String blurb, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 30),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Ar.headingStyle(19, forText: title)),
        const SizedBox(height: 4),
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

/// The port, in a field that keeps its own text.
///
/// Its own widget because a controller rebuilt on every poll loses the caret
/// twice a second, which is a field nobody can type four digits into.
class _PortField extends StatefulWidget {
  const _PortField({required this.port, this.onSubmitted});

  final String port;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PortField> createState() => _PortFieldState();
}

class _PortFieldState extends State<_PortField> {
  late final _controller = TextEditingController(text: widget.port);

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
