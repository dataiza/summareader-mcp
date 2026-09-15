import 'dart:io';

import 'package:flutter/material.dart';
import 'package:summareader_ui/summareader_ui.dart';

/// The shell this window's dialogs sit in, so they read as pages of the
/// console rather than as whatever the platform's dialog looks like.
///
/// The sync server's console has had this since pairing needed it; this is the
/// same thirty lines, because both windows are the app's design and a question
/// asked in one should look like a question asked in the other. It uses only
/// `Ar` and `PrimaryButton`, both vendored and present — the design package
/// has never held a dialog and cannot be extended from here.
///
/// Unlike that one there is no automatic Done button: the questions below all
/// have a real answer to give, and a dialog with both an answer and a Done is
/// a dialog where the answer looks optional.
Future<void> showConsoleDialog(
  BuildContext context,
  String title,
  Widget body,
) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: Ar.bg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Ar.radiusLg),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(26, 26, 26, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Ar.headingStyle(22, forText: title)),
            const SizedBox(height: 16),
            body,
          ],
        ),
      ),
    ),
  ),
);

/// Where the decrypted library goes, asked once.
///
/// Only when nothing else said — a `cache_dir` key, SUMMAREADER_MCP_CACHE, or
/// `--library` all mean the question is answered. Returns null when the window
/// was dismissed without an answer, which leaves the default and asks again.
Future<String?> askWhereTheLibraryGoes(
  BuildContext context,
  String proposed,
) async {
  final controller = TextEditingController(text: proposed);
  String? answer;

  await showConsoleDialog(
    context,
    'Where should the library go?',
    Builder(
      builder: (dialogContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'This mirror keeps a decrypted copy of your library here. It runs '
            'no retention, so over time it holds more than any of your devices '
            'do — treat the directory the way you treat the library itself.',
            style: Ar.bodyStyle(13.5, color: Ar.dim(0.75), height: 1.6),
          ),
          const SizedBox(height: 14),
          ArField(controller: controller, background: Ar.neutral100),
          const SizedBox(height: 10),
          Text(
            'You can change this later in Configuration.',
            style: Ar.bodyStyle(12.5, color: Ar.dim(0.6), height: 1.5),
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: PrimaryButton(
              label: 'Keep it here',
              onTap: () {
                answer = controller.text.trim();
                Navigator.of(dialogContext).pop();
              },
            ),
          ),
        ],
      ),
    ),
  );

  controller.dispose();
  return (answer?.isEmpty ?? true) ? null : answer;
}

/// What to do about a library already in the chosen directory.
///
/// **Keep** is the answer, and the only one reachable by pressing Return.
/// Unlike the sync server's database this one *is* rebuildable — from the log,
/// by pulling everything again — so deleting it costs time rather than
/// anything irreplaceable. That is why the wording here is milder, and it is
/// the only difference between the two windows' version of this question.
///
/// Returns true when it was emptied.
Future<bool> askAboutWhatIsAlreadyThere(
  BuildContext context,
  String dir,
) async {
  var deleted = false;

  await showConsoleDialog(
    context,
    'There is already a library here',
    Builder(
      builder: (dialogContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$dir holds a mirror already. Keeping it is almost certainly what '
            'you want: it is where a reinstall picks up without pulling your '
            'whole library again.',
            style: Ar.bodyStyle(13.5, color: Ar.dim(0.75), height: 1.6),
          ),
          const SizedBox(height: 12),
          Text(
            'Starting again deletes it and pulls everything from the server '
            'once more. Nothing is lost that the log cannot rebuild — only the '
            'time and the bandwidth it takes.',
            style: Ar.bodyStyle(13, color: Ar.dim(0.7), height: 1.6),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PillButton(
                label: 'Start again',
                onTap: () async {
                  final navigator = Navigator.of(dialogContext);
                  deleted = await emptyLibrary(dir);
                  navigator.pop();
                },
              ),
              const SizedBox(width: 9),
              PrimaryButton(
                label: 'Keep it',
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  return deleted;
}

/// Removes the library and the files that belong to it, and nothing else.
///
/// Named files rather than the directory: on macOS the config file is in here
/// too — one directory is the whole installation there — and it holds the
/// master key, which is the one thing in this design that is not recoverable.
///
/// The write-ahead log goes with it, or SQLite opens the next library on top
/// of the last one's uncommitted pages.
Future<bool> emptyLibrary(String dir) async {
  var removed = false;
  for (final name in const [
    'library.sqlite',
    'library.sqlite-wal',
    'library.sqlite-shm',
  ]) {
    final file = File('$dir/$name');
    if (file.existsSync()) {
      file.deleteSync();
      removed = true;
    }
  }
  return removed;
}

/// Whether [dir] already holds a library.
bool holdsALibrary(String dir) => File('$dir/library.sqlite').existsSync();

/// Whether to put the console in the applications menu, asked once.
///
/// An AppImage is a file in a folder and nothing knows about it: no icon, no
/// menu entry, and a task switcher showing an unnamed window. Fixing that means
/// writing into somebody's home, so it is asked rather than done — writing
/// there unbidden the first time a program runs is what makes people distrust
/// this format.
///
/// Returns true to add it. A no is remembered as firmly as a yes, or "once"
/// becomes "every launch until you give in".
Future<bool> askAboutTheMenu(BuildContext context) async {
  var wanted = false;

  await showConsoleDialog(
    context,
    'Add this to your applications?',
    Builder(
      builder: (dialogContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'This is a single file you downloaded, so nothing has told your '
            'desktop about it. Adding it writes a launcher entry and icons '
            'into ~/.local/share — no root, nothing outside your home, and '
            'reversible from Configuration.',
            style: Ar.bodyStyle(13.5, color: Ar.dim(0.75), height: 1.6),
          ),
          const SizedBox(height: 12),
          Text(
            'Leave it out and this keeps working exactly as it does now: run '
            'the file. You will not be asked again either way.',
            style: Ar.bodyStyle(13, color: Ar.dim(0.7), height: 1.6),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PillButton(
                label: 'Not now',
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
              const SizedBox(width: 9),
              PrimaryButton(
                label: 'Add it',
                onTap: () {
                  wanted = true;
                  Navigator.of(dialogContext).pop();
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );

  return wanted;
}
