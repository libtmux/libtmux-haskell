# Preview and apply a tmuxp workspace

Use the [example's Git project](../examples/load-workspace/cabal.project.vcs)
to fetch both packages. Add `libtmux-haskell-workspace` to your executable's
dependencies and import `LibTmux.Workspace`. Pass the YAML bytes and their
absolute parent directory to `planTmuxp`.
`previewWorkspace` gives you the resolved windows, pane commands and
working directories. Planning reads no files or process environment.

The example opens its own daemon and applies the plan to a new session.

```console
$ cabal run --verbose=0 load-workspace
```

<!-- example: load-workspace -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Bytes
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Workspace qualified as Workspace
import System.Directory (getCurrentDirectory)

main :: IO ()
main = do
  directory <- getCurrentDirectory
  plan <- require
    (Workspace.planTmuxp (Workspace.defaultPlanInputs directory) document)
  let preview = Workspace.previewWorkspace plan
  putStrLn ("session: " <> Text.unpack preview.sessionName)
  putStrLn ("planned windows: " <> show (NonEmpty.length preview.windows))
  Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    session <- Workspace.applyWorkspace server plan
    snapshot <- Tmux.capture server
    links <- require (Tmux.linksForSession snapshot session)
    panes <- traverse (require . Tmux.panesForWindow snapshot . (.window)) links
    putStrLn ("applied panes: " <> show (sum (map length panes)))

document :: ByteString
document = Bytes.unlines
  [ "session_name: review"
  , "windows:"
  , "  - window_name: editor"
  , "    layout: even-horizontal"
  , "    panes: [blank, blank]"
  , "  - window_name: tests"
  ]

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
```

<!-- example-output: load-workspace -->
```text
session: review
planned windows: 2
applied panes: 3
```

## Supply paths and environment

`defaultPlanInputs` takes the configuration file's directory. Set
`homeDirectory` for `~` and `variables` for `$NAME` and `${NAME}` expansion.
The plan resolves a relative window path against its session path and a
relative pane path against its window path. Missing paths stop apply before
session creation. Quote environment values that YAML could read as numbers
or booleans.

With a named `layout`, apply arranges the window as each pane is added.
An unspecified layout leaves each native split in place. Automatic window
indices start from the server's base index.

Session environment applies to the new session. A pane's environment
overrides the window's pane environment. The plan supports shell text and
the inherited `enter` policy. Apply starts tmux's configured shells. For
panes that will receive text, each shell must execute a `printf` probe within
one second of sending it. The probe can appear in the terminal or shell
history. If any acknowledgement is missing, apply retains the new session
for recovery before it sends the workspace's commands.

See the [catalogue results](../workspace/test/fixtures/tmuxp/compatibility.json)
for preview comparisons and support by syntax form. The tests isolate forms
that have no matching catalogue example and record any refusal. The package
accepts named tmux layouts and rejects script hooks, plugins, timing and
option fields. See [fixture provenance](../workspace/test/fixtures/tmuxp/README.md).

## Recover a partial apply

`applyWorkspace` returns a `SessionRef` for the new session. Capture its
links or use `killSession` to retire it. A duplicate session name stops
creation.

Read `workspaceRecoveries` from an exception context after a failure or
cancellation. `workspaceRecoverySession` gives you the exact new reference
when it was observed. If initial creation was interrupted, inspect
`pendingWorkspaceCreation` with `LibTmux.Recovery` before deciding how to
retire the session. Never substitute a session name for missing evidence.
