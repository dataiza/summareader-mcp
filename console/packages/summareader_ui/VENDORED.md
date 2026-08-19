# This is a copy

The original lives in the SummaReader app's repository, at
`packages/summareader_ui`, and that copy is the one to edit. This one is here
because a `git:` dependency on that repository needs a credential to read its
metadata, and the machines that build this console do not have one — so the
look arrives as files rather than as a resolution step that can fail on a
build server at midnight.

Update it with:

    scripts/sync-ui.sh [path-to-summareader-checkout]

which defaults to `../summareader`. `console/test/vendored_ui_test.dart` fails
when the two have drifted and a sibling checkout is there to compare against,
so a copy left behind is caught here rather than noticed as the console slowly
stopping looking like the app.

The fonts the package asks for — Caprasimo and Figtree — are copied by the
same script into `console/assets/fonts`, because a package cannot carry the
assets an application has to declare.

Nothing here is edited in place, `dart format` included: reformatting the copy
is drift like any other, and the test above will say so. Format it where it
lives and copy it again.
