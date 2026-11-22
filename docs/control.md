# Observe control notifications

Open [`withControl`](../src/LibTmux/Server.hs) with a session reference from
the connected server. Use [`readControlEvent`](../src/LibTmux/Control.hs)
in STM to receive notifications as tmux sends them. The callback starts
after tmux acknowledges the selected session.

Run from a [provisioned checkout](../.github/CONTRIBUTING.md#toolchain).

```console
$ cabal run --verbose=0 watch-window
```

<!-- example-output: watch-window -->
```text
window renamed to control-demo
split pane removed
```

## Wait for pane state

Call [`waitForPaneState`](../src/LibTmux/Server.hs) with the pane reference and a
`WindowSlot`. `PaneActive` checks the selected link in that session and the active
pane of its window. `PaneDead` observes a retained dead pane. `PaneAbsent` observes
that the physical pane is gone from the daemon.

The waiter confirms the result in a fresh snapshot. Control notifications
wake it promptly. Bounded rechecks cover silent changes such as pane death
and window-link swaps. The deadline covers attachment and capture. Control
cleanup has a separate budget.

`PaneStateMatched` carries the confirming snapshot. On timeout, daemon loss or observer failure, keep
any returned capture owner and use [recovery](capture.md#errors-and-recovery)
to inspect it. A full observer queue returns `PaneStateObserverEnded ControlOverflow`. The waiter observes
current state, so a change that reverses before the next capture can go unseen.

## Queue and terminal state

The default queue holds 32 events. Set `eventCapacity` from 1 through 128.
Inspect an available result with `pollControlEvent` or combine a blocking
read with other STM actions.

A rename names the physical window and carries the serialized name from tmux.
Other native notifications retain their bytes. Set `includePaneOutput` to
receive pane output records as well. The stream exposes only observations.
The attached client does not count toward layout sizing or update the session
environment. tmux counts the attachment and can run attach hooks.

Each line is bounded to 64 KiB. A slow consumer receives its queued prefix,
then `ControlOverflow` when the next event would exceed the queue. Malformed
framing and daemon loss also end the stream explicitly. `ControlExited`
carries the native exit reason when supplied.

Finish the callback to retire the client and its reader. The borrowed
daemon stays running. If cleanup is incomplete, retain the exception
context with `tryWithContext` and import `LibTmux.Recovery` to inspect
and resume the original control owner.

## Complete program

<!-- example: watch-window -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Ascii
import Data.List.NonEmpty (NonEmpty (..))
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (die)
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)

main :: IO ()
main = do
  let cat = Creation.DirectCommand
            (Os.fromBytestring "/bin/cat")
            (Os.fromBytestring "-" :| [])
      options = Creation.defaultSessionOptions {Creation.process = cat}
  Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server ->
    bracket
      (Tmux.createSession server options)
      (Tmux.killSession server . (.session))
      $ \created -> do
        Tmux.withControl
          server
          created.session
          Tmux.defaultControlOptions
          $ \stream -> do
            Tmux.renameWindow server created.window "control-demo"
            observed <- timeout
              1000000
              (waitForRename stream (Tmux.windowId created.window))
            label <- maybe (die "No window rename arrived") pure observed
            Ascii.putStrLn ("window renamed to " <> label)

        let slot = Creation.WindowSlot created.session created.windowIndex
        split <- Tmux.splitPane server slot created.pane
          Creation.defaultSplitOptions {Creation.splitProcess = cat}
        Tmux.sendKeys server split.pane (Tmux.NamedKeys ("C-d" :| []))
        Tmux.waitForPaneState
          server
          slot
          split.pane
          Tmux.PaneAbsent
          Tmux.defaultPaneStateWait
          >>= \case
            Tmux.PaneStateMatched _ -> putStrLn "split pane removed"
            _ -> die "The split pane was not observed leaving"

waitForRename :: Tmux.Control -> Tmux.WindowId -> IO ByteString
waitForRename stream expected =
  atomically (Tmux.readControlEvent stream) >>= \case
    Right (Tmux.WindowRenamed window label) | window == expected -> pure label
    Right _ -> waitForRename stream expected
    Left terminal ->
      die ("Control stream ended before the rename: " <> show terminal)
```
