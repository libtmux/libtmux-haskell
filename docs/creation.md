# Create a session and use its targets

[`createSession`](../src/LibTmux/Server.hs) creates a detached session through
an existing [`Server`](../src/LibTmux/Server.hs). It returns the actual session,
initial window and pane references printed by tmux. Use those references for
commands, then capture again to observe the resulting graph.

Start the [README's private demonstration server](../README.md), then run
from a [provisioned checkout](../.github/CONTRIBUTING.md#toolchain):

```console
$ cabal run --verbose=0 create-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

This program starts `/bin/cat -` directly, renames its window, sets its pane
title and checks duplicate-name rejection. The old capture stays unchanged;
the new capture and created references remain readable after the handle closes.
The session and its process keep running. Follow the README's teardown commands
when finished; closing a library handle does not kill the daemon or its panes.
Run the mutation guide's separate example on a fresh demonstration server.

<!-- example: create-session -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Create native targets, refresh their graph, and retain detached values.
module Main (main) where

import Control.Exception (ExceptionWithContext (..), rethrowIO)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    width <- require "Width" (Tmux.mkDimension 120)
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions
          { Creation.name = Just "workspace"
          , Creation.windowName = Just (Tmux.labelFromBytes "editor")
          , Creation.width = Just width
          , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
          }
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      before <- Tmux.capture server
      created <- Tmux.createSession server options
      Tmux.renameWindow server created.window "api"
      Tmux.setPaneTitle server created.pane "editor-ready"
      after <- Tmux.capture server
      duplicate <- Tmux.tryTmux (Tmux.createSession server options)
      rejected <- case duplicate of
        Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure True
        Left problem -> rethrowIO problem
        Right _ -> die "Duplicate creation unexpectedly succeeded"
      pure (created, before, after, rejected)
    case result of
      Left problem -> rethrowIO problem
      Right (created, before, after, rejected) -> do
        session <- require "Created session" (Tmux.lookupSession after created.session)
        window <- require "Created window" (Tmux.lookupWindow after created.window)
        pane <- require "Created pane" (Tmux.lookupPane after created.pane)
        links <- require "Created session links" (Tmux.linksForSession after created.session)
        label <- require "Window label" (Tmux.labelText window.name)
        putStrLn $ "created session: " <> Text.unpack session.name
        putStrLn $ "initial window: " <> Text.unpack label
        putStrLn $ "pane title: " <> Text.unpack pane.title
        putStrLn $ "same created targets: " <> show (session.ref == created.session && window.ref == created.window && pane.ref == created.pane)
        putStrLn $ "captured sessions: " <> show (length (Tmux.sessions before)) <> " -> " <> show (length (Tmux.sessions after))
        putStrLn $ "created window links: " <> show (length links)
        putStrLn $ "duplicate name rejected: " <> show rejected
  _ -> die "Usage: create-session SOCKET TMUX_EXECUTABLE"

require :: Show problem => String -> Either problem a -> IO a
require context = either (die . ((context <> ": ") <>) . show) pure
```

Program output:

<!-- example-output: create-session -->
```text
created session: workspace
initial window: api
pane title: editor-ready
same created targets: True
captured sessions: 1 -> 2
created window links: 1
duplicate name rejected: True
```

## Options and process modes

Start from [`defaultSessionOptions`](../src/LibTmux/Creation.hs). Import
`LibTmux.Creation` qualified for option updates, as the program does; several
observation types also have fields named `name`, `width` and `height`.

Session and window names and the working directory stay literal through tmux
format parsing. Checked dimensions must fit the native command's range.
Environment entries override session variables; tmux's configured inheritance
and `update-environment` rules still apply. Relative paths use the calling
client's working directory. The library captures that OS context in `IO` as
part of the command deadline. Options omit `Show` because argv and environment
values can contain credentials.

[`InitialProcess`](../src/LibTmux/Creation.hs) distinguishes native modes:

- `DefaultProcess` uses tmux's configured default command or default shell.
- `ShellCommand` passes command bytes to tmux's default shell. An empty script
  still starts a shell, which can exit immediately.
- `DirectCommand` executes the program with a nonempty list of arguments.
  tmux treats a single argv entry as shell input, so the type requires at
  least one argument after the executable.

There is no processless session mode. The ordinary creation operation also
requires an existing daemon; it does not bootstrap a first server, reuse an
existing session, attach a terminal or replace a daemon after failure.

## Receipts and fresh observations

[`CreatedSession`](../src/LibTmux/Creation.hs) is a historical receipt. It contains
opaque references from this Server generation, the initial window index and
the daemon PID reported with them. It is not a snapshot or a liveness check.
An after-hook can rename or destroy a target before creation returns. A receipt
also does not prove that the initial process successfully executed or that a
hook's background work finished.

[`capture`](../src/LibTmux/Server.hs) and the indexed
[`lookupSession`, `lookupWindow` and `lookupPane`](../src/LibTmux/Snapshot.hs)
read those identities as observed in the supplied new snapshot. A deleted
target returns a pure lookup error. References from an earlier generation
cannot target a reopened handle. A stale or deleted reference never silently
selects a replacement by name.

## Failure, deadlines and recovery

[`createSessionWith`](../src/LibTmux/Server.hs) accepts `MutationOptions`.
Its positive timeout, at most ten seconds, covers context acquisition,
admission and the complete command response; the default is one second.
It does not bound the lifetime of the created session or its process.

Protocol and bound checks fail before dispatch. tmux also validates its own
input rules and current server state. A duplicate session name raises
`MutationRejected`; a successful primary creation followed by hook failure
raises `MutationAppliedWithErrors`. Neither failure implies rollback of
independent hook effects. Timeout, cancellation and incomplete responses can
leave the command's outcome unknown. Creation never automatically retries.

[`tryTmux`](../src/LibTmux/Server.hs) preserves library errors and their exception
context. It lets asynchronous cancellation propagate. When catching cancellation
at an application boundary, retain the context from `tryWithContext` too.
Use [`creationRecoveries`](../src/LibTmux/Server.hs) to find the correlated
operation owner rather than searching all Runtime operations.

For each owner, `creationOperation` and `creationGeneration` identify the
request. `creationReceipt` reads any complete IDs already observed without
contacting tmux. `Nothing` does not prove that creation had no effect.
`inspectCreationRecovery` distinguishes logical outcome from native cleanup.
`awaitCreationRecovery` joins the original child and decoder;
`resumeCreationRecovery` resumes existing cleanup. Neither repeats creation.

If logical uncertainty remains, `detachCreationRecovery` explicitly relinquishes
that responsibility while preserving physical cleanup owners. It does not kill
the created session. Handle any scope-level cleanup owners separately through
[`cleanupRecoveries`](../src/LibTmux/Server.hs). The
[shared Runtime guide](shared-runtime.md) explains ownership across handles;
the [mutation guide](mutations.md) describes the common outcome vocabulary.
