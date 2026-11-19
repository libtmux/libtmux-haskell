# Create sessions, windows and panes

[`createSession`](../src/LibTmux/Server.hs) creates a detached session through
an existing [`Server`](../src/LibTmux/Server.hs). It returns the actual session,
initial window and pane references printed by tmux. Use those references for
commands, then capture again to observe the resulting graph.
[`createWindow` and `splitPane`](../src/LibTmux/Server.hs) use the same historical
receipts and recovery path with explicit placement and pane targets.

Start the [README's private demonstration server](../README.md), then run
from a [provisioned checkout](../.github/CONTRIBUTING.md#toolchain):

```console
$ cabal run --verbose=0 create-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

The program reads one option type and one hook scope from
[the daemon's catalogue](options.md). It checks an empty value, a removal
marker and an absent entry
in the new session's [environment](mutations.md#read-and-change-the-environment).
It adds a window and splits an explicit pane, then links that window
at a second index, selects an exact pane, tiles the window and removes the
extra link. The new pane disables terminal echo, prints a readiness marker and starts `/bin/cat -`.
The caller waits for the marker and [captures a baseline](mutations.md#read-pane-text).
It [sends literal text and a named Enter](mutations.md#send-input-to-a-pane),
then [waits for fresh text](mutations.md#wait-for-pane-text) from the pane.
The program checks duplicate-name rejection, removes its targets and verifies
that the original sessions survive. Captures remain readable after the handle
closes. Follow the [README's teardown](../README.md#clean-up)
for the borrowed demonstration server.

<!-- example: create-session -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Create native targets, refresh their graph, and retain detached values.
module Main (main) where

import Control.Exception (ExceptionWithContext (..), rethrowIO)
import Control.Monad (unless)
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
    extraIndex <- require "Second link index" (Tmux.mkWindowIndex 4)
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions
          { Creation.name = Just "created-workspace"
          , Creation.windowName = Just (Tmux.labelFromBytes "editor")
          , Creation.width = Just width
          , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
          }
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      let capabilities = Tmux.serverCapabilities server
      history <- maybe (die "Missing history-limit option") pure
        (Tmux.lookupOption capabilities "history-limit")
      createdHook <- maybe (die "Missing after-new-session hook") pure
        (Tmux.lookupHook capabilities "after-new-session")
      putStrLn $ "history-limit kind: " <> show history.optionKind
      putStrLn $ "after-new-session scopes: " <> show createdHook.hookScopes
      before <- Tmux.capture server
      created <- Tmux.createSession server options
      let environment = Tmux.SessionEnvironment created.session
          key = "LIBTMUX_EXAMPLE_STATE"
      Tmux.setEnvironment server environment key Tmux.Visible ""
      empty <- Tmux.getEnvironment server environment key
      Tmux.markEnvironmentRemoved server environment key
      removed <- Tmux.getEnvironment server environment key
      Tmux.unsetEnvironment server environment key
      absent <- Tmux.getEnvironment server environment key
      unless (empty == Just (Tmux.EnvironmentValue Tmux.Visible "")
          && removed == Just (Tmux.EnvironmentRemoved Tmux.Visible) && absent == Nothing)
        (die "Expected distinct empty, removed and absent entries")
      Tmux.renameWindow server created.window "api"
      Tmux.setPaneTitle server created.pane "editor-ready"
      added <- Tmux.createWindow server (Creation.NextFree created.session)
        Creation.defaultWindowOptions {Creation.windowLabel = Just "worker", Creation.windowProcess = options.process}
      let workerSlot = Creation.WindowSlot added.session added.windowIndex
          secondLink = Creation.WindowSlot added.session extraIndex
      split <- Tmux.splitPane server workerSlot added.pane
        Creation.defaultSplitOptions
          { Creation.direction = Creation.LeftRight
          , Creation.size = Creation.SplitPercent 25
          , Creation.splitProcess = Creation.ShellCommand
              "stty -echo; printf 'input-ready\\n'; exec /bin/cat -"
          }
      Tmux.linkWindow server workerSlot secondLink
      Tmux.selectWindowLink server secondLink
      Tmux.selectExactPane server secondLink split.pane
      Tmux.selectLayout server secondLink Tmux.Tiled
      linked <- Tmux.capture server
      linkedSlots <- require "Worker links" (Tmux.linksForSession linked added.session)
      let workerIndices = [Tmux.windowIndexValue link.index | link <- linkedSlots, link.window == added.window]
      Tmux.unlinkWindow server secondLink
      _ <- awaitText server split.pane Tmux.defaultPaneWait "input-ready"
      baseline <- Tmux.capturePane server split.pane Tmux.defaultPaneCapture
      Tmux.sendKeys server split.pane (Tmux.LiteralText "Enter")
      Tmux.sendKeys server split.pane (Tmux.NamedKeys ("Enter" :| []))
      screen <- awaitText server split.pane
        Tmux.defaultPaneWait {Tmux.waitMatch = Tmux.FreshSince baseline} "Enter"
      after <- Tmux.capture server
      duplicate <- Tmux.tryTmux (Tmux.createSession server options)
      rejected <- case duplicate of
        Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure True
        Left problem -> rethrowIO problem
        Right _ -> die "Duplicate creation unexpectedly succeeded"
      Tmux.killSession server created.session
      let disposable = options {Creation.name = Nothing}
      windowOwner <- Tmux.createSession server disposable
      Tmux.killWindow server windowOwner.window
      paneOwner <- Tmux.createSession server disposable
      Tmux.killPane server paneOwner.pane
      remaining <- Tmux.capture server
      pure (created, added, split, before, after, screen, workerIndices, rejected, remaining)
    case result of
      Left problem -> rethrowIO problem
      Right (created, added, split, before, after, screen, workerIndices, rejected, remaining) -> do
        session <- require "Created session" (Tmux.lookupSession after created.session)
        window <- require "Created window" (Tmux.lookupWindow after created.window)
        pane <- require "Created pane" (Tmux.lookupPane after created.pane)
        worker <- require "New window" (Tmux.lookupWindow after added.window)
        panes <- require "New window panes" (Tmux.panesForWindow after added.window)
        splitPane <- require "Split pane" (Tmux.lookupPane after split.pane)
        links <- require "Created session links" (Tmux.linksForSession after created.session)
        label <- require "Window label" (Tmux.labelText window.name)
        workerLabel <- require "New window label" (Tmux.labelText worker.name)
        putStrLn $ "created session: " <> Text.unpack session.name
        putStrLn "session environment: empty, removed, absent"
        putStrLn $ "initial window: " <> Text.unpack label
        putStrLn $ "pane title: " <> Text.unpack pane.title
        putStrLn $ "same created targets: " <> show (session.ref == created.session && window.ref == created.window && pane.ref == created.pane)
        putStrLn $ "captured sessions: " <> show (length (Tmux.sessions before)) <> " -> " <> show (length (Tmux.sessions after))
        putStrLn $ "created session links: " <> show (length links)
        putStrLn $ "new window: " <> Text.unpack workerLabel
        putStrLn $ "new window panes: " <> show (length panes)
        putStrLn $ "same worker window at indices: " <> show workerIndices
        putStrLn $ "split exact target: " <> show (splitPane.window == added.window && split.session == added.session && split.windowIndex == added.windowIndex)
        putStrLn $ "captured pane rows match height: " <> show
          (toInteger (length (Text.lines (Tmux.paneText screen))) == Tmux.dimensionValue splitPane.height)
        putStrLn "captured pane text"
        putStr (Text.unpack (Text.unlines (filter (not . Text.null) (Text.lines (Tmux.paneText screen)))))
        putStrLn $ "duplicate name rejected: " <> show rejected
        putStrLn $ "original sessions after removal: " <> show
          (map (.ref) (Tmux.sessions remaining) == map (.ref) (Tmux.sessions before))
  _ -> die "Usage: create-session SOCKET TMUX_EXECUTABLE"

awaitText :: Tmux.Server -> Tmux.PaneRef -> Tmux.PaneWaitOptions -> Text.Text -> IO Tmux.PaneText
awaitText server pane options expected =
  Tmux.waitForText server pane options expected >>= \case
    Tmux.PaneTextMatched screen -> pure screen
    Tmux.PaneTextTimedOut _ _ -> die "Timed out waiting for pane text"
    Tmux.PaneTextExited _ -> die "Pane exited before producing text"

require :: Show problem => String -> Either problem a -> IO a
require context = either (die . ((context <> ": ") <>) . show) pure
```

Program output:

<!-- example-output: create-session -->
```text
history-limit kind: NumberKind
after-new-session scopes: [SessionScope]
created session: created-workspace
session environment: empty, removed, absent
initial window: api
pane title: editor-ready
same created targets: True
captured sessions: 1 -> 2
created session links: 2
new window: worker
new window panes: 2
same worker window at indices: [1,4]
split exact target: True
captured pane rows match height: True
captured pane text
input-ready
Enter
duplicate name rejected: True
original sessions after removal: True
```

## Link, select and arrange windows

[`linkWindow`](../src/LibTmux/Server.hs) takes a source slot and a vacant
destination slot. The new slot points to the same physical window and starts
unselected. Use [`selectWindowLink`](../src/LibTmux/Server.hs) to activate a
specific session/index, even when the same window appears at two indices.

[`selectExactPane`](../src/LibTmux/Server.hs) takes a window slot and an exact
pane reference. The pane must belong to that slot's current window.
[`selectLayout`](../src/LibTmux/Server.hs) applies one of the five layout names
shared by tmux 3.3a and 3.8. It affects the physical window seen through every
link and can unzoom it. Capture again to read the active pane and geometry.

[`unlinkWindow`](../src/LibTmux/Server.hs) removes only the named link and
refuses to remove the last one. Native session groups can propagate link
changes to their members. Use the `With` variants for explicit deadlines.

## Remove a target

Use [`killSession`](../src/LibTmux/Server.hs) for a session,
[`killWindow`](../src/LibTmux/Server.hs) for a physical window and all its
links, and [`killPane`](../src/LibTmux/Server.hs) for a pane. tmux closes a
window when its last pane is removed, and a session when its last window
closes. Capture again to see what remains.

The `With` variants take [`MutationOptions`](../src/LibTmux/Server.hs).
A missing native target fails with `MutationRejected`. A foreign or offline
reference fails with `InvalidTarget` before dispatch. Command completion
confirms the removal response. Observe descendant process exit separately.

## Options and process modes

Start from [`defaultSessionOptions`](../src/LibTmux/Creation.hs). Import
`LibTmux.Creation` qualified for option updates, as the program does; several
observation types also have fields named `name`, `width` and `height`.

Session and window names and the working directory stay literal through tmux
format parsing. Checked dimensions must fit the native command's range.
Environment entries override session variables; tmux's configured inheritance
and `update-environment` rules still apply. Relative paths use the calling
client's working directory. The library captures that OS context in `IO` as
part of the command deadline. Options omit
[`Show`](https://hackage.haskell.org/package/base/docs/Prelude.html#t:Show)
because argv and environment values can contain credentials.

[`InitialProcess`](../src/LibTmux/Creation.hs) distinguishes native modes:

- `DefaultProcess` uses tmux's configured default command or default shell.
- `ShellCommand` passes command bytes to tmux's native creation handler. Session
  creation runs even an empty script through the default shell. An empty split
  command instead follows tmux's processless-pane behavior.
- `DirectCommand` executes the program with a nonempty list of arguments.
  tmux treats a single argv entry as shell input, so the type requires at
  least one argument after the executable.

There is no processless session mode. The ordinary creation operation also
requires an existing daemon; it does not bootstrap a first server, reuse an
existing session, attach a terminal or replace a daemon after failure.

## Window placement and pane targets

[`createWindow`](../src/LibTmux/Server.hs) takes a
[`WindowPlacement`](../src/LibTmux/Creation.hs) and `WindowOptions`. Start from
`defaultWindowOptions` and choose `NextFree session`, `At slot`, `Before slot`
or `After slot`. A `WindowSlot session index` means the current occupant of
that position at execution time. It does not freeze a captured window identity.
On a vacant relative slot, tmux creates at that index without shifting links.
`After` refuses index 2147483647 before dispatch because no larger signed
window index exists.

The default `RefuseOccupied` policy reports a native rejection when an exact
slot is occupied. `ReplaceOccupied` removes that link before creating a new
window. Other links can keep the old physical window alive. Insertion can
shift indices and replacement can remove a link before a later failure; neither
mode promises rollback. Session groups can propagate these effects.

`windowLabel` and `windowDirectory` stay literal. Window creation inherits the
target session's geometry; `windowEnvironment` and `splitEnvironment` override
only the new pane's environment. `windowProcess` and `splitProcess` choose its
native initial process.
`selectWindow = True` requests selection in the target session. Replacing its current
link can force selection even when the option is false. Reuse by name remains
outside this API because native reuse can return no creation receipt.

[`splitPane`](../src/LibTmux/Server.hs) takes a `WindowSlot`, an explicit
`PaneRef` and `SplitOptions`. The pane must belong to that slot's physical
window when tmux executes the command. This also distinguishes two indices
linked to the same physical window. A missing pane or changed slot occupant
fails without choosing another active pane.

Start from `defaultSplitOptions`. `LeftRight` splits across columns;
`TopBottom` splits across rows. `before` puts the new pane left or above the
anchor; `fullWindow` spans the perpendicular window dimension. `SplitCells`
and `SplitPercent` request the new pane's extent. Percentages are 1 through 100;
cells and link indices fit tmux's signed 32-bit domain. Native border and
layout constraints can clamp or refuse a requested size. Capture again to
read actual dimensions. `selectPane` requests the new pane as active; `zoom`
zooms the window or keeps it zoomed. Floating-pane extensions remain separate.

## Receipts and fresh observations

[`CreatedEntities`](../src/LibTmux/Creation.hs) is a historical receipt. It contains
opaque references from this Server generation, the execution-time window index
and the daemon PID reported with them. It is not a snapshot or a liveness check.
`CreatedSession`, `CreatedWindow` and `CreatedPane` name the results of each
operation. Only the session command creates all three entities; window creation
retains its existing parent session, and a split retains its existing window.
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

[`createSessionWith`, `createWindowWith` and `splitPaneWith`](../src/LibTmux/Server.hs)
accept `MutationOptions`.
Its positive timeout, at most ten seconds, covers context acquisition,
admission and the complete command response; the default is one second.
It does not bound the lifetime of the created entities or their processes.

Invalid options raise `InvalidMutationArgument` before admission. Encoded
command arguments fit a 16,364-byte message, including terminators and literal
text escaping. The client invocation also counts toward the argv limit.

The caller's environment shares the native launch budget with argv: at most
4,096 entries and 64 KiB, including paths, terminators and pointer storage.
Exceeding that budget raises `InvalidConfiguration` before admission. Neither
refusal retains a creation operation or includes environment values.

tmux also validates its own input rules and current server state. A duplicate
session name raises
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
contacting tmux. [`Nothing`](https://hackage.haskell.org/package/base/docs/Data-Maybe.html#v:Nothing)
does not prove that creation had no effect.
`inspectCreationRecovery` distinguishes logical outcome from native cleanup.
`awaitCreationRecovery` joins the original child and decoder;
`resumeCreationRecovery` resumes existing cleanup. Neither repeats creation.

If logical uncertainty remains, `detachCreationRecovery` explicitly relinquishes
that responsibility while preserving physical cleanup owners. It does not kill
the created entities. Handle any scope-level cleanup owners separately through
[`cleanupRecoveries`](../src/LibTmux/Server.hs). The
[shared Runtime guide](shared-runtime.md) explains ownership across handles;
the [mutation guide](mutations.md) describes the common outcome vocabulary.
