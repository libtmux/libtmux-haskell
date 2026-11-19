{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation

main :: IO ()
main = do
  alias <- either (fail . show) pure (Tmux.mkWindowIndex 4)
  snapshot <- Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    created <- Tmux.createSession server Creation.defaultSessionOptions
      { Creation.name = Just "demo"
      , Creation.process = Creation.ShellCommand "exec /bin/cat -"
      }
    Tmux.linkWindow server (Creation.WindowSlot created.session created.windowIndex)
      (Creation.WindowSlot created.session alias)
    Tmux.capture server

  putStrLn $ "Physical windows: " <> show (length (Tmux.windows snapshot))
  forM_ (Tmux.windowLinks snapshot) $ \link ->
    putStrLn $ "Window index " <> show (Tmux.windowIndexValue link.index)
      <> " refers to " <> Text.unpack (Tmux.renderWindowId (Tmux.windowId link.window))
