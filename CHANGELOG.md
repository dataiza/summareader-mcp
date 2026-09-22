# Changelog

The version a release is tagged with is the one in `summareader_mcp/__init__.py`,
and the release workflow refuses to publish without a section here that names
it.

## Unreleased

### It knows what a group is

The app files sources in groups and sync has carried that all along, but this
server had never been taught the word: the record was skipped — which is what
it is meant to do with anything it does not recognise — so a model reading the
library saw a flat list of sources the reader had stopped seeing.

Groups arrive now, and there is a **list_groups**: every group with how many
sources it holds and how many articles that reaches. **search_library** and
**library_report** both take a `groups` filter, by title or by id.

One asymmetry worth knowing, and the tool descriptions say it: several tags
*narrow*, and several groups *widen*. A source is in at most one group, so
asking for two as an `and` would ask for something that cannot exist.

A group whose sources have not arrived yet, or a source naming a group that
has not, is not an error — the source is simply ungrouped until the rest
catches up.

## 0.7.0

### The tags are visible now

Search could always be narrowed by tag, but nothing anywhere said what the
tags were, and no article that came back said what it was filed under — so the
one filter built on a vocabulary could only be used by somebody who already
knew the words.

There is a new **list_tags**, which is every tag in the library with the number
of articles each one reaches, a feed's tags counting towards the articles in it
exactly as search matches them. And every article returned — by a search, by
the recent list, by reading one in full — now carries its tags, so the
vocabulary can be learnt from an answer rather than asked for separately.

### A report can be narrowed the way a search can

**library_report** accepted five of the ten ways a search can be narrowed, so
a report on everything tagged `rust` that you have not read could not be
asked for although both halves of it already worked. It now takes every
filter search does, under the same names: read dates, unread, summarized and
tags.

A report that matches nothing says so, rather than handing back a title, a
count of zero and an empty table.

## 0.6.0

### Settings reach a running server

**Sync every** meant what it said only from the next start, and so did a
re-paired server or a new device token: the loop read the configuration once
when the thread began and then ran on it for ever. The console is a different
process and had no way to tell it otherwise, which is why three separate
complaints were one bug.

The loop watches the file it was configured from. A `stat` of it every few
seconds is the whole cost, and it is read again only when that says something
moved; a file caught mid-write, or one somebody is editing by hand, is ignored
until it parses again rather than taken as an instruction to stop. **Sync
every** now takes effect where it is typed and does not wait the old interval
out, and the sync server and the token are used at the next pull, with nothing
restarted — an outbound connection can be dialled again without taking a port
away from anybody.

**Port** is the exception and is now written and left for the next start. It is
a listening socket, moving it means stopping the server under whatever is
connected to it, and the old number exposes nothing the new one would not. The
bind address still takes effect at once, because narrowing it is how a library
comes off the network and that has to happen when it is asked for. Each row
says which of the three it is.

### The Restart button has somewhere to go

After downloading a new version the window said it was in place and offered no
way to use it: the field the button is gated on was declared, read twice, and
never written.

### Start and Sync now are on the page the window opens on

They were behind Configuration, which is where somebody goes when something is
wrong. These two are what the window is opened to do. Above the library rather
than below, because what those numbers say depends on whether the server is
running — and still drawn where they cannot be pressed, beside the sentence
that says why.

### How often it asks now sits beside who it asks

**Sync automatically** and **Sync every** were on the server's page while the
address, the token and the key they use were on another. That page is renamed
with them: it was "From the config file", which described where its values came
from rather than what it is for.

### The library says when it last received something

It said **never** on a machine that syncs constantly — truthfully, because both
of the things it was reading live in memory and go when the server stops. It
now shows the newest instant the data itself carries.

### A typed value is kept when you leave the box

Only Enter used to commit. Leaving the field, changing the page or closing the
window keeps it too — but only when the value parses and differs from the one
stored, and a refused value puts the box back. The pairing box is the
exception and still wants Enter: it is the same widget, and committing it
because a mouse left the field would pair with a server nobody chose.

## 0.5.0

### The window can start the mirror itself

Opening the console and pressing **Start** only ever had one answer on a
machine set up for it. **Configuration → This program → Start the mirror when
this opens** makes opening the window the whole of it. Off unless it is turned
on, and never a stop: a window opening is no reason to take down a mirror
somebody left running, and one already up — a user service that came back at
login, another console left open — is left where it is.

It starts nothing unless the three things a serving mirror is set up with are
there: a bind address, a port and a bearer token. With one of them missing
nothing is started and the window says which, rather than leaving a start that
quietly did nothing to look like a mirror that failed to bind. That is stricter
than the **Start** button, which lets loopback through without a token, and
deliberately so — somebody pressing Start is there to read what happened.

The switch stays on the page whether or not the token is there yet, since the
row that generates one is two pages away and a setting that vanished until it
was would be one nobody could find. **This program** is now offered to a
tarball too, which until now had nothing on that page.

### A generated bearer token says so

**Generate** wrote a new token, put it on the clipboard and left the row
looking exactly as it had a moment before. The row now carries **set** or **not
set** beside the button — whether there is one, never what it is — so pressing
it changes the page it was pressed on, and the message that appears says a
*new* token was written.

## 0.4.13

### The install question, asked as one

The dialog that appears when a downloaded release is run opened with **This is
not the copy in your applications menu** and then spent two paths, a move and a
deletion getting to the point. From the outside it is one sentence: a new
release was downloaded, it was run, and yes installs it. So that is the title
now, with the version in it, and **Install** on the button.

None of the detail is gone — the path the menu starts, the path being run, what
moving does and what is deleted are all under **What this does**, shut until
somebody wants them.

## 0.4.12

### Configuration is pages

It was one column of five sections, which on a small window is a scroll with
the thing you came for somewhere in the middle of it. One subject per page —
**The server**, **Library**, **Sync**, **This program** — chosen by name, the
way the app spells the same idea.

A page with nothing on it is not offered: a tarball has no image to replace,
so **This program** is simply absent rather than opening on an explanation.
And a section no longer repeats the name of the page it is on.

**Without this window** is gone. It said where a service comes from on a build
that cannot install one, which is a sentence about something else.

## 0.4.11

### The mirror stopped pulling after a day, and it was the window's fault

A mirror started from the console ran for about a day and then did nothing:
no pulls, and an HTTP port still listening that never answered. Reported as
"auto-sync does not work", and everything about the configuration was right —
`sync` on, `poll_seconds` at its default, the library matching the app's item
for item up to the moment it stopped.

`Process.start` gives a child a pipe for stdout and another for stderr, and
**a pipe nobody reads fills up** — 64 KB on Linux — after which the child
blocks for ever on its next log line. The console captured both and read
neither. The mirror logs every pull, so it wrote its way into a wall: asleep
in `anon_pipe_write`, holding a listening socket it could no longer answer.

Both streams are read now, and the last 300 lines are kept rather than
discarded — a mirror misbehaving is exactly when somebody wants them, and the
reason this was invisible for a day is that nothing had them. The test writes
1.4 MB from a child without pausing: stop reading it and the test hangs, which
is the failure itself.

**Restart the mirror once to escape it** — Stop, then Start, in the console.

## 0.4.10

### Restart now

Beside the line that says the update is in place. The new version is on disk
and the old one is the process on screen — which is exactly why replacing it
was safe — so nothing changes until it is started again, and that was a
sentence asking you to do it.

## 0.4.9

### An updated image renames itself to the version it holds

A self-update writes the new program into the old path — that is what makes
the swap atomic — so `SummaReaderMCP-0.4.8-x86_64.AppImage` went on saying
0.4.8 while holding 0.4.9, and the launcher entry named that file. The file is
renamed afterwards now, and the menu entry follows it. Nothing outside the
name changes, and an entry naming another copy is left alone.

## 0.4.8

### Checking for an update no longer installs one

Finding a newer release now says which version it found and waits: **Download**
or **Cancel**. Replacing the program somebody is running is the one control on
that page that changes this program, and it was happening because they pressed
"check".

The download says how far along it is, as a percentage under the version, and
the line stays afterwards to say the new version starts next time. It is
written beside the old image and swapped only at the end, so an interrupted
download costs a stray file rather than a working program.

## 0.4.7

### Choosing the app's library was a one-way door

Pointing the console at the app's own library turned off the whole row that
chose it: both segments, the path field and **Browse…** all went dead together,
because they were drawn only for a console that runs a mirror — and one reading
the app's library runs none. The app's library was then the last answer this
window would ever accept. The row is editable wherever there is a config file
to write into.

**Its own copy** also handed back the path belonging to the mode it was
leaving, which in that direction is the app's `.sqlite` file rather than a
directory a mirror can fill. It goes back to where the config says its own copy
lives, and finding a library already there is not an obstacle: that one is this
mirror's own, from before somebody pointed the console at the app's.

**And the row says read-only next to the buttons.** "Opened read-only. Nothing
here writes to the app's library, and nothing pulls into it" — under the two
segments, where the decision is made, rather than only in the hint beside them.

### Start at login is not offered inside an AppImage

The unit it writes names the frozen mirror *inside the image's mount*: a path
that exists only while the window is open, and a different one at every launch.
So the switch wrote a service that could not start. It is absent there, and
**This program** says where a service does come from — `scripts/install.sh`
from the release, which writes the unit around a binary that stays put.

## 0.4.6

### The dialog about the menu entry says what it is about to do

Downloading a new release by hand and running it out of `~/Downloads` is
installing it, and the dialog that noticed treated it as a discrepancy: two
paths and a warning about what could break. It now says what pressing the
button does — moves this copy to `~/Applications` and starts it from the menu
from now on — and the button says **Use this one**.

**And the copy it replaces is deleted**, when there is one: an AppImage in
`~/Applications` that the entry named until now. Left alone it is a second
program a version behind, checking GitHub for itself and startable from a file
manager. Nothing outside `~/Applications` is ever removed, and never the copy
the entry now names. The dialog names the file before it happens.

## 0.4.5

### Syncing is a switch, and it is not offered where there is nothing to switch

**Sync automatically**, in The server, turns the pulling loop on and off. Off
is a mirror that holds what it already has and asks for nothing — while a sync
server is down, or on a machine that should read a library and never add to it.
Sync now still pulls, and so does `pull` on the command line: this is the loop,
not the verb. The key is `sync`, `SUMMAREADER_MCP_SYNC` in the environment, and
the interval below it is hidden while the loop is off, because how often a loop
that does not run would have run is a number about nothing.

**A mirror reading the app's own library shows neither.** It opens that file
read-only and has never started a loop over it — the server has said "reading
…, read-only; not syncing" since that mode existed — but the window went on
offering the schedule anyway. The section now says whose library it is instead.

## 0.4.4

### How often it pulls, and a token it can make for you

Two things the config file has always held and no window could touch.

**Sync every _n_ seconds** is a field in The server, beside the Sync now it
automates. It writes `poll_seconds`, which is what the mirror has read since it
existed and what the environment's `SUMMAREADER_MCP_POLL` sets. Anything under
30 is refused where it is typed: the mirror takes whatever number it is given,
and a five is a mirror asking a sync server twelve times a minute for ever.

**Generate**, beside the bind address, mints the bearer token that address
needs — 32 random bytes — writes it, and puts it on the clipboard. That is the
one moment it is readable, because a client has to be given it; a token nobody
can read is a token nobody can use. It is not drawn in the window, which is
still the rule the master key follows for a stronger reason.

Both are absent when there is no config file to write into: a `--remote` or
`--library` console is reading somebody else's arrangement.

### Fixed

- **Pairing named the mirror after the other device.** The payload's
  `from_device` is the name of the machine that *showed* the code, and it was
  being written as this mirror's own `name` — so a console paired from a laptop
  called Mainframe appeared in the app's device list as Mainframe. It is "MCP
  mirror" now unless the payload names this one.
- **An existing library can be chosen by its directory.** "An existing library"
  refused everything but a path ending in the `.sqlite` file itself, while the
  Browse… dialog beside it picks directories — so the button and the field
  disagreed about what an answer looked like. A directory is accepted and the
  database inside it found, as the mode's own description always said. The hint
  now names where the app keeps it: `~/.local/share/sk.dataiza.summareader`, or
  `…summareader.premium` for Premium.

### Changed

- **In the applications menu** is gone from Configuration. The offer on first
  run, and the question asked when the entry points somewhere stale, already
  cover it; a switch that duplicates them is a third place for the same answer
  to live.

## 0.4.3

### The launcher entry said "SummaReader Sync Server"

It was ported from the sync server's console with the application id replaced
and the four display strings left alone, so anyone who added this to their
applications menu got an icon naming the wrong program. The AppImage's own
copy of the entry was right all along; only the installed one was wrong.

The file's own comment had warned about this — "two spellings of the same entry
is how the menu and the window stop matching" — and nothing enforced it. A test
does now, in both repositories: it installs an entry and compares every display
field against the copy packed into the image.

Toggling **In the applications menu** off and on in Configuration rewrites it.

## 0.4.2

### The menu entry survives tidying your downloads

Adding the console to the applications menu wrote the path the AppImage had at
that moment — which is the downloads folder, because that is where a file you
just downloaded is. Empty that folder, as people do, and the icon in the
launcher starts nothing at all.

It moves the image to `~/Applications` first now, which is where AppImages
conventionally live, and the entry names it there. **Moved, not copied**: two
copies of a program that each replace themselves from GitHub are two programs a
month later, and which one runs depends on which icon was clicked. The dialog
says so before it does it.

And if the entry already names somewhere else — the file was moved by hand, or
a second copy is being run — the console says so on launch and offers to point
it here. That is the only moment anything is in a position to notice, because
the program that would have complained is the one that is not there.

## 0.4.1

Two things the AppImage in 0.4.0 shipped without, both found while giving the
sync server's console the same treatment.

- **The licence text is inside the image.** An image is a single file with no
  directory beside it, so `usr/share/doc` is the only place there is — and the
  AGPL is not shy about the text travelling with the binary. 0.4.0 carried it
  nowhere.
- **The 48×48 icon is back.** The build looked for `magick`, which is
  ImageMagick 7's name for the tool; Debian and Ubuntu ship version 6, whose
  package provides `convert` and no `magick` at all. So installing ImageMagick
  on the runner changed nothing: the build took its graceful branch, said so,
  and released a size short. It looks for both names now.

The second one is the bill for degrading rather than failing, which is still
the right trade for an optional icon — but a skip is silent, and a silence
ships.

## 0.4.0

### Pairing, instead of editing three values in by hand

`server`, `token` and `master_key` were typed into the config file, which
means a base64 key retyped across a desk — the one transcription here where a
wrong character costs a library that will not decrypt.

The console's Configuration page has a **Pair** button. It takes what the app's
Settings → Sync → Add another device → **Copy MCP config** put on the
clipboard, and the pairing code beside that button as well: the same three
values under the names the QR uses, letters and all, so a code drawn by an
older release still pairs. There is a field beside it for when the clipboard is
not the route.

All four keys are written in **one save**. Half a configuration is a mirror
that does not start and says nothing about which half is missing. Everything
else in the file — comments, unknown keys, the old `http_token` spelling — is
put back exactly as it was read.

**The master key is written and never shown.** No field holds it, no row
displays it, nothing logs it; the configuration list says only whether a key is
set. Accepting a whole payload at once is a different operation from editing a
secret by hand, which is what makes it acceptable at all.

Anything that will not do is a sentence and nothing is written: not JSON, a
version this console cannot read, any of the three missing, or a key that is
not 32 bytes once decoded — named by its length, never its contents.

### Browse… beside the library path

A directory picker in both modes, so the path does not have to be typed. "Its
own copy" takes the directory as picked. "An existing library" takes a
directory too and finds the app's database inside it — `summareader.sqlite`, or
`allreader.sqlite` on installs that predate a rename, the two names and the
order the app itself uses. A directory holding neither is refused with a
sentence naming both and where they were looked for.

The typed field still works, and a picked path goes through exactly the same
check as a typed one. macOS gained the user-selected-files entitlement, without
which the picker returns nothing there and says nothing about why.

### An AppImage for Linux, that updates itself

One file: `chmod +x`, run. No repository, no package manager, no root — which
is the whole reason for the format. The unpacked tarball stays for anyone
packaging this themselves.

**It updates itself.** Configuration → This program → *Check for updates* asks
GitHub for the newest release and replaces the running image. Nothing is
checked until it is pressed: a window that asks the network about itself before
anybody said so is a window nobody chose. Replacing the file a running program
started from is safe — the kernel holds the old inode until the process ends,
and the rename is atomic — and the new version is what starts next time.

**It offers, once, to join the applications menu**, writing a launcher entry
and icons into `~/.local/share`. Asked rather than done: writing into somebody's
home unbidden the first time a program runs is what makes people distrust this
format. A no is remembered as firmly as a yes.

Both controls are absent unless it *is* an AppImage. A tarball has no single
file to replace and no path worth writing into a launcher entry, so offering
either would act on something nobody chose.

### Changed

- The GTK application id is `sk.dataiza.summareader_mcp_console`; it was
  `com.dataiza.…`, the only one of the three products spelled that way. A
  `.desktop` file has to be named after it for a window to be matched to its
  launcher entry, so this was the last moment to fix it without breaking
  something.
- The icon ladder gained the 48×48 the freedesktop spec asks for, scaled at
  build time from the 512 rather than committed — a generated file in the tree
  is one nobody can regenerate when the source changes.

## 0.3.0

### The library moved out of the cache directory

`~/.local/share/summareader-mcp` on Linux, `~/Library/Application Support/
summareader-mcp` on macOS, `%LOCALAPPDATA%` on Windows. `XDG_DATA_HOME` is
honoured when it is absolute and ignored when it is not, as the specification
requires.

It was `~/.cache`, which contradicted what this file already said about the
mirror: it runs no retention, so it is the most complete copy of a library
rather than a subset of one — and `~/.cache` is what a disk cleaner empties.

**The key is still `cache_dir` and the variable is still
`SUMMAREADER_MCP_CACHE`.** Renaming them would touch both Dockerfiles, both
compose files, the unit, `run.sh`, `freeze.sh` and every install that exists,
to change a spelling.

**Nothing is moved and nothing is deleted.** A library left in the old
directory is named on stderr, once, with what happens if it is ignored — the
new one starts empty and rebuilds from the log, which costs every blob
downloaded again. Copy it across by hand to avoid that.

### The window asks where, once

On a first run, and only when nothing else said — a `cache_dir`, the
environment variable or a named library all mean the question is answered.
Accepting writes the key, which is what stops it asking again. A library
already in the chosen directory is kept unless you say otherwise; starting
again costs a re-pull and nothing else.

### Configuration is a button

The settings were behind a menu bar holding one submenu labelled "Console" — a
grey strip that had to be clicked to find out what was in it, and two presses
to reach its only destination. It is a pill in the header now, the way the app
spells the same control.

### Fixed

- `scripts/install.sh` put its virtualenv inside the library directory and the
  uninstall message called that directory "a cache, safe to delete" — so
  following this installer's own advice deleted the virtualenv the installed
  command is a symlink into. It has its own directory now, and the message
  says what is actually kept.
- `cache_dir` is in `summareader-mcp.example.json` at last. It has been read
  since it existed and documented in the README, and was never in the file
  people copy.

## 0.2.0

The first published build. What is in it, rather than what changed.

### The mirror

- Joins a sync library as one more device, pulls the log, and keeps a decrypted
  copy in SQLite. It holds the master key and a plaintext library — the one
  place in the design where the encryption ends, which is what it is for.
- Its own implementation of the sync protocol, checked in the test suite
  against the app's own vectors rather than sharing code with it. That is what
  lets this repository build without the app beside it.
- Runs no retention, so the mirror is the *most complete* copy of a library
  rather than a subset of one. The cache directory deserves the care the
  library does.

### Ways in

- **MCP over stdio**, which is what a client that starts its own subprocess
  wants, and needs no service at all.
- **MCP over HTTP**, for a client somewhere else. Bound to loopback unless a
  `bearer_token` is set — the installer refuses a wider address without one
  rather than serving the library to the network.
- **A command line**: `search`, `recent`, `report`, `pull`, `status`.
- **A terminal interface**, so a machine reached over ssh is not reduced to
  flags.
- **A desktop console**, a window that starts the mirror and asks it what is in
  the library. It carries its own copy of the mirror.

### Running it

- A systemd **user** service, installed by `install.sh` with no root, or a
  container from the compose file.
- Frozen with PyInstaller into one executable that needs no Python on the
  machine it runs on, and proved on every build by opening a library with it —
  which is where a frozen bundle fails, at the moment somebody uses it rather
  than at start-up.
