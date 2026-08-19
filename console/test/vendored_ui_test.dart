/// The copy of the app's look, checked against the original.
///
/// console/packages/summareader_ui is a copy — see VENDORED.md in it for why —
/// and a copy nothing compares is a copy that drifts. This is the comparison,
/// and it runs only where there is a sibling checkout to compare against: on a
/// build machine with just this repository there is nothing to be wrong about,
/// and failing there would be failing for having less of the world available.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'seed.dart';

void main() {
  test('the vendored look is the app\'s look', () {
    // Where the script defaults to, and overridable the same way, so somebody
    // whose checkout lives elsewhere can point both at it.
    final app = Directory(
      Platform.environment['SUMMAREADER'] ??
          '${repositoryRoot.parent.path}/summareader',
    );
    final original = Directory('${app.path}/packages/summareader_ui');
    if (!original.existsSync()) {
      markTestSkipped('no SummaReader checkout at ${app.path} to compare with');
      return;
    }

    final copy = Directory('${Directory.current.path}/packages/summareader_ui');
    // VENDORED.md exists only in the copy: it is the note saying it is one.
    final theirs = _files(original);
    final ours = _files(copy)..remove('VENDORED.md');
    expect(
      ours.keys.toList()..sort(),
      theirs.keys.toList()..sort(),
      reason: 'files differ — run scripts/sync-ui.sh',
    );
    for (final name in theirs.keys) {
      expect(
        ours[name],
        theirs[name],
        reason: '$name has drifted — run scripts/sync-ui.sh',
      );
    }

    // The fonts travel with it, for the same reason and by the same script.
    for (final font in const [
      'Caprasimo-Regular.ttf',
      'Figtree-Variable.ttf',
    ]) {
      expect(
        File('${Directory.current.path}/assets/fonts/$font').readAsBytesSync(),
        File('${app.path}/assets/fonts/$font').readAsBytesSync(),
        reason: '$font has drifted — run scripts/sync-ui.sh',
      );
    }
  });
}

/// Every file under [root], by its path relative to it, with its bytes.
Map<String, String> _files(Directory root) => {
  for (final entry in root.listSync(recursive: true).whereType<File>())
    entry.path.substring(root.path.length + 1): entry.readAsStringSync(),
};
