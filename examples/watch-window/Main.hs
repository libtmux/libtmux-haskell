{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Ascii
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (die)
import System.Timeout (timeout)

main :: IO ()
main = do
  let options = Creation.defaultSessionOptions {Creation.process = Creation.ShellCommand "exec /bin/cat"}
  Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server ->
    bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created ->
      Tmux.withControl server created.session Tmux.defaultControlOptions $ \stream -> do
        Tmux.renameWindow server created.window "control-demo"
        observed <- timeout 1000000 (waitForRename stream (Tmux.windowId created.window))
        label <- maybe (die "No window rename arrived") pure observed
        Ascii.putStrLn ("window renamed to " <> label)

waitForRename :: Tmux.Control -> Tmux.WindowId -> IO ByteString
waitForRename stream expected = atomically (Tmux.readControlEvent stream) >>= \case
  Right (Tmux.WindowRenamed window label) | window == expected -> pure label
  Right _ -> waitForRename stream expected
  Left terminal -> die ("Control stream ended before the rename: " <> show terminal)
