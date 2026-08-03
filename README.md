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

## The tools

| Tool | Answers |
| --- | --- |
| `search_library` | Items whose title, source, summary or address mention something |
| `recent_items` | The most recently synced items |
| `library_summary` | How much is here, how much is summarized, how far the log has been read |

Read-only, deliberately, for as long as this is a prototype. A tool that wrote
to the log would be a second writer of a format the app owns, and getting that
wrong corrupts a library rather than returning a bad answer.

## Running it

Configuration is three values: the sync server, a device token, and the master
key. Put them in a file rather than the environment — `docker inspect` prints
an environment, and a file can be mounted read-only.

```sh
cp allreader-mcp.example.json allreader-mcp.local.json   # then fill it in
```

The device token comes from a paired device (`POST /enroll`) or from
`allreader-sync pair` for the first one, and is revocable. The master key is
the value the pairing QR carries — **it is not revocable, and anything holding
it can read everything.**

### As a subprocess, for a local MCP client

```sh
dart run bin/allreader_mcp.dart            # stdio, which is what clients expect
```

### In Docker

```sh
docker compose up -d
curl http://127.0.0.1:8100/health
```

HTTP rather than stdio, because a container is not a subprocess its client can
start.

Set `http_token` in the config and callers must present it as a bearer token.
Without one the port is open to anyone who can reach it, and the server says
so at startup — the encryption ends at this process, which is what it is for
and why it needs a boundary of its own. `/health` never needs the token: it
reports whether the process is up and nothing about what it holds, and a
health check that needs a secret breaks the day the secret rotates.

If the sync server is another container on the same host, put both on one
network and use its service name; `host.docker.internal` will not reach a sync
server that is bound to localhost, which its own compose does on purpose. The
compose file has the block to uncomment.

## Testing it

```sh
dart test
```

Twenty-three tests over the mirror, its cache and the configuration. The
end-to-end path — container, real sync server, real encrypted entries, tools
called over MCP — has been driven by hand and is not yet a script.

The decrypted mirror is kept in `/cache` between runs, so a restart asks for
what has arrived since rather than re-reading and re-decrypting the whole log.
It is still only a cache: deleting the volume costs one re-read and no data,
and anything unreadable in it — corrupt, half-written, or from a newer format
— is treated as empty rather than as an error.
