# Transfer and paste a named buffer

[`loadBuffer`](../src/LibTmux/Server.hs) and
[`readBuffer`](../src/LibTmux/Server.hs) preserve up to 64 KiB of binary
data, including NUL, invalid UTF-8 and a final newline. The name must be
nonempty and contain no NUL. An empty load leaves the current buffer intact.
Reading an oversized buffer raises `BufferTooLarge`.

[`pasteBuffer`](../src/LibTmux/Server.hs) takes a current buffer name and an
exact pane reference. Choose `PreserveLineFeeds` or
`LineFeedsToCarriageReturns`. The library uses raw paste on the pinned daemon.
The terminal and application can still process the input. Observe the pane
when you need to know whether the application responded.

Run from the repository root. The private daemon owns the session and its buffers.

```console
$ cabal run --verbose=0 paste-buffer
```

<!-- example: paste-buffer -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Text (Text)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (die)

main :: IO ()
main = do
  let options = Creation.defaultSessionOptions
        { Creation.process = Creation.ShellCommand
            "stty -echo; printf 'paste-ready\\n'; exec /bin/cat -"
        }
      name = "libtmux-example-paste"
      binary = "raw\NUL\255\n" :: ByteString
  Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server ->
    bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created -> do
      baseline <- observe server created.pane Tmux.defaultPaneWait "paste-ready"
      Tmux.loadBuffer server name binary
      recovered <- Tmux.readBuffer server name
      unless (recovered == binary) (die "Buffer bytes changed")
      putStrLn "NUL, invalid UTF-8 and final newline round-tripped"

      Tmux.loadBuffer server name "pasted-text\n"
      Tmux.pasteBuffer server created.pane name Tmux.PreserveLineFeeds
      _ <- observe server created.pane
        Tmux.defaultPaneWait {Tmux.waitMatch = Tmux.FreshSince baseline} "pasted-text"
      putStrLn "target pane displayed pasted-text"

observe :: Tmux.Server -> Tmux.PaneRef -> Tmux.PaneWaitOptions -> Text -> IO Tmux.PaneText
observe server pane options expected = Tmux.waitForText server pane options expected >>= \case
  Tmux.PaneTextMatched screen -> pure screen
  Tmux.PaneTextTimedOut _ _ -> die "The pane did not produce expected text"
  Tmux.PaneTextExited _ -> die "The pane exited before producing expected text"
```

<!-- example-output: paste-buffer -->
```text
NUL, invalid UTF-8 and final newline round-tripped
target pane displayed pasted-text
```
