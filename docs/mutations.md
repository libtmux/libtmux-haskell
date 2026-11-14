# Rename captured targets

[`renameSession`](../src/LibTmux/Server.hs),
[`renameWindow`](../src/LibTmux/Server.hs) and
[`setPaneTitle`](../src/LibTmux/Server.hs) act in `IO` on opaque references
from the same [`Server`](../src/LibTmux/Server.hs). Renaming a window changes
the physical window everywhere it is linked, not one session slot.

The program validates every selection before its first mutation. It changes the
server you give it, so use the [README's demo server](../README.md). Run from a
[checkout](../.github/CONTRIBUTING.md#toolchain):

```console
$ cabal run --verbose=0 mutate-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

- The session rename, window rename and title change are separate commands. A
  later failure does not undo earlier ones.
- Afterward, run the README's cleanup commands. The program leaves the daemon
  running.

<!-- example: mutate-graph -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Select physical targets, mutate them, and compare detached observations.
module Main (main) where

import Control.Exception (rethrowIO)
import Data.Function ((&))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Pane qualified as Pane
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        selected = Q.panes & Q.matching (Q.eq Pane.active True)
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      before <- Tmux.capture server
      session <- require "Session selection" (Q.exactlyOne (Tmux.sessions before))
      matches <- require "Pane query" (Q.runQuery before selected)
      pane <- require "Pane selection" (Q.exactlyOne matches)
      window <- require "Pane's window" (Tmux.lookupWindow before pane.window)

      Tmux.renameSession server session.ref "workspace"
      Tmux.renameWindow server window.ref "api #{pid};"
      Tmux.setPaneTitle server pane.ref "editor-ready"
      after <- Tmux.capture server
      pure (before, after, session, window, pane)
    case result of
      Left problem -> rethrowIO problem
      Right (before, after, session, window, pane) -> do
        changedSession <- require "Fresh session" (Tmux.lookupSession after session.ref)
        changedWindow <- require "Fresh window" (Tmux.lookupWindow after window.ref)
        changedPane <- require "Fresh pane" (Tmux.lookupPane after pane.ref)
        oldWindow <- require "Old window" (Tmux.lookupWindow before window.ref)
        oldName <- require "Old window encoding" (Tmux.labelText oldWindow.name)
        newName <- require "New window encoding" (Tmux.labelText changedWindow.name)
        let links = [link | link <- Tmux.windowLinks after, link.window == window.ref]
        putStrLn $ "session: " <> Text.unpack session.name <> " -> " <> Text.unpack changedSession.name
        putStrLn $ "window: " <> Text.unpack oldName <> " -> " <> Text.unpack newName
        putStrLn $ "pane title: " <> Text.unpack changedPane.title
        putStrLn $ "physical window links: " <> show (length links)
        putStrLn $ "same target identities: " <> show
          (session.ref == changedSession.ref && window.ref == changedWindow.ref && pane.ref == changedPane.ref)
        putStrLn $ "old snapshot values: " <> Text.unpack session.name <> ", " <> Text.unpack oldName
  _ -> die "Usage: mutate-graph SOCKET TMUX_EXECUTABLE"

require :: Show problem => String -> Either problem a -> IO a
require context = either (die . ((context <> ": ") <>) . show) pure
```

Output from the private fixture:

<!-- example-output: mutate-graph -->
```text
session: demo -> workspace
window: editor -> api #{pid};
pane title: editor-ready
physical window links: 2
same target identities: True
old snapshot values: demo, editor
```

- Reporting happens after the Server scope closes.
- The old snapshot keeps the original names; the fresh one resolves the same
  physical references.
- The two window links stay distinct.
- The literal `#{pid}` in the window name is not evaluated as a format.

## Targets, names and deadlines

- A reference from another connection generation, or from an
  [offline fixture](fixtures.md), fails with `InvalidTarget` before dispatch.
- A closed handle fails with `ServerClosed`.
- A reference does not prove the target still exists; tmux can reject one
  deleted since capture. Select the intended entity first with
  [typed queries](query.md).

Names:

- Window names are [`TmuxText`](../src/LibTmux/Snapshot.hs): bytes, with an
  explicit conversion to text that can fail. String literals work with
  [OverloadedStrings](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/overloaded_strings.html);
  `labelFromBytes` takes bytes.
- Session names and pane titles are
  [`Text`](https://hackage-content.haskell.org/package/text-2.1.3/docs/Data-Text.html#t:Text).
- tmux may reject a name its release does not accept.
- NUL and oversized encoded commands fail before dispatch.
- The pane's application can replace a title later.

Deadlines:

- Default: one second, covering submission and waiting for the response.
- Forms such as [`renameWindowWith`](../src/LibTmux/Server.hs) take
  [`MutationOptions`](../src/LibTmux/Server.hs) first, for example
  `Tmux.defaultMutationOptions {Tmux.timeout = 2}`.
- Timeouts must be positive, up to ten seconds. They bound the wait, not
  configured hooks.
- Nothing retries automatically.

## Known and uncertain outcomes

[`tryTmux`](../src/LibTmux/Server.hs) catches library operational exceptions
with their context. It lets application exceptions and asynchronous
cancellation propagate.

- `MutationRejected` means tmux rejected the primary command.
- `MutationAppliedWithErrors` means the primary command ran and a later hook
  failed. The failure does not imply rollback.
- `MutationTimedOut` means the caller deadline elapsed. It does not establish
  whether the command ran. Inspect the correlated status before deciding what
  responsibility remains.

Use the exception constructor to distinguish rejection from an applied hook
error; both have a completed `Failed` operation status. A successful response
does not establish that background jobs started by a hook have finished.

## Keep recovery ownership reachable

Read [`mutationRecoveries`](../src/LibTmux/Server.hs) from the exception
context that `tryTmux` or
[`Control.Exception.tryWithContext`](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Exception.html#v:tryWithContext)
returns. Each owner has a `mutationOperation` and `mutationGeneration`. Its
receipt keeps metadata, not the command operands or result. An operation that
was never admitted has no owner.

- [`inspectMutationRecovery`](../src/LibTmux/Server.hs) reads the status and
  native ownership locally.
- `resumeMutationRecovery` resumes cleanup without resending the command.
- `awaitMutationRecovery` waits for the local owners to retire. If cleanup may
  need resuming, inspect first. Cancelling the wait keeps the owner.
- `detachMutationRecovery` gives up the remaining responsibility. Decide who
  owns it first: detaching does not stop daemon work, release native resources
  or repeat the mutation.

An exited native child does not turn `OutcomeUnknown` into success, and
retained uncertainty can hold later commands back. After a callback or scope
cleanup fails, see [shared Runtime](shared-runtime.md).

Not implemented yet: creation, pane input, contextual window operations and
event streams; see [status](status.md).
