# Observe control notifications

Open [`withControl`](../src/LibTmux/Server.hs) with a session reference from
the connected server. Use [`readControlEvent`](../src/LibTmux/Control.hs)
in STM to receive notifications as tmux sends them. The callback starts
after tmux acknowledges the selected session.

Start the [private demonstration server](../README.md) and run from a
[provisioned checkout](../.github/CONTRIBUTING.md#toolchain).

```console
$ cabal run --verbose=0 watch-window -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

<!-- example-output: watch-window -->
```text
window renamed to control-demo
```

## Queue and terminal state

The default queue holds 32 events. Set `eventCapacity` from 1 through 128.
Inspect an available result with `pollControlEvent` or combine a blocking
read with other STM actions.

A rename names the physical window and carries the serialized name from tmux.
Other native notifications retain their bytes. Set `includePaneOutput` to
receive pane output records as well. The scope uses a read-only client that
leaves geometry and the session environment alone. tmux can run attach hooks.

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
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import System.Timeout (timeout)

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions {Creation.process = Creation.ShellCommand "exec /bin/cat"}
    Tmux.withServer config $ \server ->
      bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created ->
        Tmux.withControl server created.session Tmux.defaultControlOptions $ \stream -> do
          Tmux.renameWindow server created.window "control-demo"
          observed <- timeout 1000000 (waitForRename stream (Tmux.windowId created.window))
          label <- maybe (die "No window rename arrived") pure observed
          Ascii.putStrLn ("window renamed to " <> label)
  _ -> die "Usage: watch-window SOCKET TMUX_EXECUTABLE"

waitForRename :: Tmux.Control -> Tmux.WindowId -> IO ByteString
waitForRename stream expected = atomically (Tmux.readControlEvent stream) >>= \case
  Right (Tmux.WindowRenamed window label) | window == expected -> pure label
  Right _ -> waitForRename stream expected
  Left terminal -> die ("Control stream ended before the rename: " <> show terminal)
```
