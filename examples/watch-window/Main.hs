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
