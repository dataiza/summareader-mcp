
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

GNU Affero General Public License, version 3. The full text is in `LICENSE`.

Section 13 is the one that matters for a server: run a **modified** version
where other people can reach it over a network, and those people are entitled
to its source. Running an unmodified build from here puts no obligation on you.

SummaReader itself is a separate, proprietary program. This speaks to your
library over a network protocol and links none of the app's code.
