# SummaReader MCP server

An MCP server over your SummaReader library: it joins as one more device, keeps
a decrypted copy, and answers questions about what you have read.

**This process holds the master key and a plaintext copy of the library.** It
is the one place in the design where the encryption ends — which is what it is
for, and why it binds to loopback and refuses anything wider without a token.

## Fill in the config first

```sh
cp summareader-mcp.example.json summareader-mcp.local.json
$EDITOR summareader-mcp.local.json
```

It wants the sync server's URL, this device's token and the library's master
key. The app hands all three over in Settings → Sync → *Add another device*.
