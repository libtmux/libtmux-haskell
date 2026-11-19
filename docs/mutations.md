# Rename captured targets

[`renameSession`](../src/LibTmux/Server.hs),
[`renameWindow`](../src/LibTmux/Server.hs) and
[`setPaneTitle`](../src/LibTmux/Server.hs) act in `IO` on opaque references
from the same [`Server`](../src/LibTmux/Server.hs). Renaming a window changes
the physical window everywhere it is linked, not one session slot.

The program uses the references returned by `createSession`. Run from a
[checkout](../.github/CONTRIBUTING.md#toolchain).

```console
$ cabal run --verbose=0 mutate-graph
```

- The session rename, window rename and title change are separate commands. A
  later failure does not undo earlier ones.

<!-- example: mutate-graph -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation

main :: IO ()
main = do
  (created, before, after) <-
    Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
      created <- Tmux.createSession server Creation.defaultSessionOptions
        { Creation.name = Just "demo"
        , Creation.windowName = Just "editor"
        , Creation.process = Creation.ShellCommand "exec /bin/cat -"
        }
      before <- Tmux.capture server
      Tmux.renameSession server created.session "workspace"
      Tmux.renameWindow server created.window "api #{pid};"
      Tmux.setPaneTitle server created.pane "editor-ready"
      after <- Tmux.capture server
      pure (created, before, after)

  previous <- either (fail . show) pure
    (Tmux.lookupSession before created.session)
  current <- either (fail . show) pure
    (Tmux.lookupSession after created.session)
  window <- either (fail . show) pure (Tmux.lookupWindow after created.window)
  pane <- either (fail . show) pure (Tmux.lookupPane after created.pane)
  label <- either (fail . show) pure (Tmux.labelText window.name)
  putStrLn $ "Session: " <> Text.unpack previous.name
    <> " -> " <> Text.unpack current.name
  putStrLn $ "Window: " <> Text.unpack label
  putStrLn $ "Pane title: " <> Text.unpack pane.title
```

Output from the program.

<!-- example-output: mutate-graph -->
```text
Session: demo -> workspace
Window: api #{pid};
Pane title: editor-ready
```

- Reporting happens after the Server scope closes.
- The old snapshot keeps the original names; the fresh one resolves the same
  physical references.
- The literal `#{pid}` in the window name is not evaluated as a format.

## Send input to a pane

[`sendKeys`](../src/LibTmux/Server.hs) takes an exact `PaneRef` and
`PaneInput`. Pass `LiteralText "Enter"` to type the five characters.
`NamedKeys ("Enter" :| [])` sends one key. The
[creation example](creation.md) shows both requests to a newly created pane.

Import `(:|)` from `Data.List.NonEmpty` for a named key sequence. tmux
checks every name before the library sends the sequence. An invalid name
raises `InvalidMutationArgument` before any keys are sent. Use
`sendKeysWith` to set one deadline for validation and sending.

Success confirms that tmux processed the input request. Observe the pane
separately when your program needs evidence that the application responded.

## Read pane text

[`capturePane`](../src/LibTmux/Server.hs) takes an exact pane reference.
Start with `defaultPaneCapture` for the visible rows in plain Unicode.
Use `paneText` to read the captured text. The
[creation example](creation.md) captures its own pane.

Set `rows` to `RowsBetween (-10) (-1)` for ten rows before the first
visible row. Offsets are inclusive and accepted from -2147483647 through
32767. tmux clamps them to the rows it retained. Set `rendering` to `AnsiStyled` to keep tmux's color and
style escapes. Empty rows remain in either format.

The byte limit applies before UTF-8 decoding. An oversized capture raises
`PaneTextTooLarge` instead of returning clipped text. The transport limit
also covers the enclosing reply and any hook output.
An after-hook failure raises `PaneCaptureHookFailed` with its diagnostic.

## Wait for pane text

[`waitForText`](../src/LibTmux/Server.hs) looks for a case-sensitive substring.
With `defaultPaneWait`, the first visible match is enough and the deadline
is one second.

For a fresh match, take a `capturePane` baseline before input and set
`waitMatch = FreshSince baseline`. Use the same pane, row range and rendering.
The wait needs either observed absence followed by presence or an additional
occurrence. Moving an old prompt or repainting it in place supplies no new
evidence. Pick a marker the application prints so ordinary terminal echo
cannot satisfy the wait. The [complete example](creation.md) disables echo
and observes its own process.

The result is `PaneTextMatched`, `PaneTextTimedOut` or `PaneTextExited`.
A timeout or exit carries the last complete capture when available. A timeout
during a capture can also carry a [recovery owner](#keep-recovery-ownership-reachable).
The first capture runs immediately. After a nonmatch, the library checks the
pane and waits up to 100 ms before reading again. One deadline bounds all these
steps.

## Read and change the environment

[`getEnvironment`](../src/LibTmux/Server.hs) looks up a name in
`GlobalEnvironment` or `SessionEnvironment session`. A session lookup reads
that table directly. A missing name returns `Nothing`. A missing session
raises `EnvironmentReadRejected`.

[`setEnvironment`](../src/LibTmux/Server.hs) stores literal bytes with
`Visible` or `Hidden` visibility. Hidden entries stay in tmux and are omitted
when it starts a process. Names must be nonempty and cannot contain NUL or
`=`. Values cannot contain NUL. Values can contain newlines and invalid UTF-8.

Use [`markEnvironmentRemoved`](../src/LibTmux/Server.hs) to mask a value
that a new process would otherwise inherit. Use
[`unsetEnvironment`](../src/LibTmux/Server.hs) to delete the entry from
the selected table. The [creation example](creation.md) observes an empty
value, a removal marker and an absent entry.

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
- NUL and encoded command arguments over 16,364 bytes fail before dispatch.
  The limit includes terminators, format expansion and escaped separators.
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

- `InvalidConfiguration` identifies the invalid setting, such as a mutation
  deadline outside its supported range.
- `InvalidMutationArgument` carries the typed operand failure and its field
  key. The [resizing program](resizing.md) checks the refused pane height.
- `InvalidTarget` reports a foreign generation or offline reference.
- `MutationRejected` means tmux rejected the primary command.
- `MutationAppliedWithErrors` means the primary command ran and a later hook
  failed. The failure does not imply rollback.
- `MutationTimedOut` means the caller deadline elapsed. It does not establish
  whether the command ran. Inspect the correlated status before deciding what
  responsibility remains.

Use the exception constructor to distinguish rejection from an applied hook
error; both have a completed `Failed` operation status. A successful response
does not establish that background jobs started by a hook have finished.

`OperationFailed` retains the original synchronous backend exception. The
scope preserves application exceptions and asynchronous cancellation.

## Keep recovery ownership reachable

Read [`mutationRecoveries`](../src/LibTmux/Recovery.hs) from the exception
context that `tryTmux` or
[`Control.Exception.tryWithContext`](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Exception.html#v:tryWithContext)
returns.

- Each owner has a `mutationOperation` and `mutationGeneration`.
- Its receipt keeps metadata, not the command operands or result.
- An operation that was never admitted has no owner.

Then:

- [`inspectMutationRecovery`](../src/LibTmux/Recovery.hs) reads the status and
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

See [implementation status](status.md) for other operations.
