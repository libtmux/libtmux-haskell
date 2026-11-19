# Read and change tmux options and hooks

Set a local history limit with [`setOption`](../src/LibTmux/Server.hs) and
read it with [`readOption`](../src/LibTmux/Server.hs). Register one indexed
rename hook with [`setHook`](../src/LibTmux/Server.hs), inspect its definition
with [`readHook`](../src/LibTmux/Server.hs), then observe its effect.

Start the [private demonstration server](../README.md) and run from a
[provisioned checkout](../.github/CONTRIBUTING.md#toolchain).

```console
$ cabal run --verbose=0 configure-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

<!-- example-output: configure-session -->
```text
local history-limit = 500
rename hook recorded the change
```

The program removes its session. Follow the
[README's teardown](../README.md#clean-up) for the demonstration server.

## Select a store

| Store | Target |
| --- | --- |
| Server | `ServerOptions` |
| Session default | `GlobalSessionOptions` |
| Exact session | `SessionOptionsAt session` |
| Window default | `GlobalWindowOptions` |
| Physical window | `WindowOptionsAt window` |
| Exact pane | `PaneOptionsAt pane` |

`LocalOption` reads the selected store. `EffectiveOption` includes native
inheritance. An empty `StringValue` and an absent value are distinct.
`unsetOption` removes an override or resets a built-in global value.
User options use an at sign followed by ASCII letters, digits, hyphens,
underscores or dots. Their values remain literal bytes and cannot contain NUL.

Built-in scalar operations use definitions from the pinned releases, from
3.3a through 3.8. An incompatible scope or kind raises `InvalidSetting`
before dispatch. tmux checks its own value constraints. Option arrays are
listed in the catalogue. Their mutation APIs remain open.

Hooks use session, window or pane stores according to the event's native
scope. `setHook` replaces one numeric entry. tmux parses its command source
when registering it. `readHook` returns the local native listing, keeping
keys and line endings. `unsetHook` clears the local override. Custom hook
operations and writing named keys remain open.

Reads are bounded to 64 KiB. A failed after-hook raises
`SettingReadHookFailed`; the reader does not use hook output as a value.
See [mutation recovery](mutations.md) for command outcomes and deadlines.

## Find a built-in name

Use [`serverCapabilities`](../src/LibTmux/Server.hs) to read the version
of the daemon you opened. Pass those capabilities to
[`lookupOption`](../src/LibTmux/Options.hs) or
[`lookupHook`](../src/LibTmux/Options.hs). Use the full native name, such
as `history-limit` or `after-new-session`. The
[creation example](creation.md) prints the option's value kind and the
hook's scope.

[`knownOptions`](../src/LibTmux/Options.hs) lists names, types, supported
scopes, array shape and named choices.
[`knownHooks`](../src/LibTmux/Options.hs) lists events and their scopes.
Both report when each entry became available within the pinned releases.

The catalogue selects the latest pinned table at or below the daemon's
reported release. The pins span tmux 3.3a through 3.8. Entries already
available at 3.3a report that release as their first qualified version.
A newer daemon can have additional entries. See the
[tmux source pins and table digests](../scripts/generate_options/sources.json).


## Complete program

<!-- example: configure-session -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions {Creation.process = Creation.ShellCommand "exec /bin/cat"}
    Tmux.withServer config $ \server ->
      bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created -> do
        let local = Tmux.SessionOptionsAt created.session
            event = "after-rename-window"
        Tmux.setOption server local "history-limit" (Tmux.NumberValue 500)
        stored <- Tmux.readOption server local Tmux.LocalOption "history-limit"
        case stored of
          Just (Tmux.NumberValue rows) -> putStrLn ("local history-limit = " <> show rows)
          _ -> die "Expected a local numeric history limit"
        Tmux.setHook server local event 0 "set-option @last-rename seen"
        hook <- Tmux.readHook server local event
        unless (hook == Just "after-rename-window[0] set-option @last-rename seen\n")
          (die "Expected one entry in the local rename hook")
        Tmux.renameWindow server created.window "review"
        observed <- Tmux.readOption server local Tmux.LocalOption "@last-rename"
        unless (observed == Just (Tmux.StringValue "seen")) (die "The rename hook did not run")
        putStrLn "rename hook recorded the change"
  _ -> die "Usage: configure-session SOCKET TMUX_EXECUTABLE"
```
