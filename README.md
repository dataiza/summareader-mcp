# allreader-mcp

An MCP server that pairs with an AllReader sync server **as a device**, keeps a
decrypted copy of the library, and answers questions about it.

Prototype. It reads; it does not yet write.

## Why it is a device and not part of the server

The sync server holds opaque ciphertext and no keys — that is the whole design,
and it is what "encrypted end-to-end, including on servers we run" means. So an
MCP server running *on* the sync server could serve almost nothing: it cannot
read a title, a summary, or anything else worth asking about.

This runs where the keys are instead. It pairs like any other device, gets the
master key the same way a second phone does, and decrypts what it reads. That
means it is **revocable like any other device**, which is the property that
makes it safe to run at all.

## What that costs

Its local copy is plaintext. Whoever can read that disk can read the whole
library.

So the copy is a **cache**, deliberately: rebuildable from the log, safe to
delete, never the only copy of anything. Delete it and the next run rebuilds
it. Two consequences worth stating rather than discovering:

- Run it on a machine whose disk you trust, and encrypt that disk.
- **Do not run it on the same host as your sync server** without meaning to.
  That host then holds plaintext, which quietly undoes the sentence at the top
  for your own deployment.

## Shared code, not copied code

The envelope format, the key hierarchy and the sync client come from
`allreader_core`, a pure-Dart package in the app's repository, by path
dependency. None of it is reimplemented here.

That is not tidiness. A second client that packs its bytes differently writes a
log the first client cannot read, and nothing would say so until somebody
tried. Extracting the wire format into that package — it had been a private
method inside the app — was the first thing this prototype changed.

## Running it

```sh
dart pub get
dart test
```

There is no entry point yet: the mirror and its tests are the part that had to
be proved first, because everything else depends on being able to read the log
at all.
