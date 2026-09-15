/// Choosing a directory, behind a seam.
///
/// The picker is a native dialog on every platform this ships to, which means
/// a test cannot open one and cannot dismiss one — and a widget test cannot
/// answer a platform channel at all, so a button that called the plugin
/// directly would be a button no test could press. Everything either side of
/// the dialog is ordinary code and worth testing: what a picked directory
/// becomes, and what happens when somebody changes their mind.
///
/// Wired the way the app wires its own chooser: the window installs the real
/// one, and a test installs something that answers without a screen.
library;

import 'package:file_selector/file_selector.dart';

import 'mirror.dart';

abstract interface class DirectoryChooser {
  /// The directory chosen, or null when the dialog was dismissed.
  Future<String?> chooseDirectory({String? startingIn});
}

class PlatformDirectoryChooser implements DirectoryChooser {
  const PlatformDirectoryChooser();

  /// A directory in both modes, never a file.
  ///
  /// "Its own copy" wants one anyway — the mirror makes `library.sqlite`
  /// inside it. "An existing library" wants the app's database, and making
  /// somebody navigate to a `.sqlite` file in an application support
  /// directory is the thing this button exists to stop; the file inside is
  /// found by name instead. See `appLibraryIn`.
  @override
  Future<String?> chooseDirectory({String? startingIn}) =>
      getDirectoryPath(initialDirectory: startingIn);
}

/// What a Browse… press comes back with: a path to hand to the library row, a
/// sentence to show instead, or neither because the dialog was dismissed.
///
/// A function rather than a method on the window, so the two answers that are
/// easy to get wrong — a directory holding no library, and a picker somebody
/// closed — can be asked for without a screen. Dismissing changes nothing at
/// all: it is the other half of a typo costing a sentence rather than a
/// library.
///
/// The path it returns is not checked here. `libraryRefusal` stays the one
/// place that decides whether a path is acceptable, and a picked one goes
/// through it exactly like a typed one.
Future<({String? path, String? refusal})> chooseLibrary(
  DirectoryChooser chooser, {
  required bool existing,
  String? startingIn,
}) async {
  final picked = await chooser.chooseDirectory(startingIn: startingIn);
  if (picked == null) return (path: null, refusal: null);
  if (!existing) return (path: picked, refusal: null);
  final found = appLibraryIn(picked);
  return found == null
      ? (path: null, refusal: noLibraryIn(picked))
      : (path: found, refusal: null);
}
