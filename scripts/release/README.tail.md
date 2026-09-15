
## Or as a container

```sh
docker compose up -d
```

The `Dockerfile` here installs the wheel in this bundle rather than building
anything. The wheel and not the binary beside it, because a frozen bundle
carries the libc of the machine that froze it and a Debian image is not that
machine.

## Or as a subprocess of your MCP client

The stdio transport, which needs no service and no port:

```json
{
  "command": "/path/to/summareader-mcp",
  "args": ["serve"],
  "env": { "SUMMAREADER_MCP_CONFIG": "/path/to/summareader-mcp.local.json" }
}
```

## Or from the terminal

```sh
./summareader-mcp status
./summareader-mcp pull
./summareader-mcp search climate --format md
./summareader-mcp recent --limit 20
./summareader-mcp ui           # the full terminal interface
```

## The cache

The decrypted mirror is rebuildable from the log and safe to delete. It is also
the *most complete* copy of your library, because a mirror runs no retention.
Treat the directory the way you would treat the library itself.

## Licence

Copyright © 2026 Dataiza s. r. o., Slovakia. Downloading a build grants you the
right to run it; it does not grant the right to redistribute it or to take it
apart.
