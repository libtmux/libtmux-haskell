# Inspect a Haskell application's tmux daemon through MCP

Keep the Haskell application's [`withOwnedServer`](../src/LibTmux/Server.hs)
callback running while the agent inspects it. Get the absolute socket from
`(serverInfo snapshot).socketPath` after `capture`. For a borrowed daemon,
use the socket your application passed to `serverConfig`.

Configure your MCP client with the same socket. The `libtmux-mcp` adapter
owns the stdio connection. The Haskell scope owns the daemon and its cleanup.

```json
{
  "mcpServers": {
    "application-tmux": {
      "command": "uvx",
      "args": ["libtmux-mcp==0.1.0a22"],
      "env": {
        "LIBTMUX_SOCKET_PATH": "/absolute/path/to/private/socket",
        "LIBTMUX_TOOLSETS": "inspect"
      }
    }
  }
}
```

If the application uses a specific tmux executable, pass its absolute path
as `LIBTMUX_TMUX_BIN` too. See the [adapter release](https://pypi.org/project/libtmux-mcp/0.1.0a22/)
and the [MCP client setup guide](https://libtmux-mcp.git-pull.com/clients/).

## Discover the application pane

1. Refresh the client's tool list. It should include `list_sessions`,
   `list_panes` and `capture_pane`.
2. Call `list_sessions` and keep the returned `session_id` of the session you
   need, such as `$0`.
3. Call `list_panes` with that `session_id`. Pass the selected `pane_id`, such
   as `%0`, to `capture_pane` when you need the visible text.

The adapter returns native IDs. Within Haskell, use the `SessionRef` or
`PaneRef` from a fresh capture on the same `Server`. See [targeting and
recovery](mutations.md#targets-names-and-deadlines).

## Run a command in an owned pane

For a pane running an interactive POSIX shell on your private daemon, set
`LIBTMUX_TOOLSETS` to `inspect,execute` and refresh the tool list. Use
`send_keys` for interactive input and `run_command` for command completion.
For example, call `run_command` with the pane ID you discovered.

```json
{
  "pane_id": "%0",
  "command": "printf 'agent-%s\\n' operated; exit 7",
  "timeout": 0.8
}
```

The result contains `agent-operated` in `output`, `exit_status` of `7`,
and `timed_out` of `false`. Keep daemon retirement with `withOwnedServer`.
[Adapter tool registration](https://github.com/tmux-python/libtmux-mcp/blob/1e0c9bc29b6bda00460a854a9bb69ff28ad7f314/src/libtmux_mcp/tools/pane_tools/__init__.py#L84-L108)

## Work on the Haskell application

For a Haskell code change, start with the [working examples](README.md), check
[`serverCapabilities`](../src/LibTmux/Server.hs) for release-specific operations,
and use the [API reference](api.md) for exact types and recovery behavior.
