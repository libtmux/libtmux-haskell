{-# LANGUAGE OverloadedRecordDot #-}

-- | Share Runtime resources while keeping Server lifetimes independent.
module Main (main) where

import Control.Exception (ExceptionWithContext (..))
import Control.Monad (forM_, unless)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
    snapshot <- Tmux.withRuntime $ \runtime ->
      Tmux.withServerIn runtime config $ \outer -> do
        first <- Tmux.capture outer
        closed <- Tmux.withServerIn runtime config $ \inner -> do
          unless (Tmux.serverGeneration inner /= Tmux.serverGeneration outer) $
            fail "independent handles shared a connection generation"
          captured <- Tmux.capture inner
          case Tmux.panes captured of
            pane : _ -> unless (Tmux.lookupPane first pane.ref == Left Tmux.ForeignGeneration) $
              fail "a reference crossed independent handle generations"
            [] -> fail "the owned example fixture has no pane"
          pure inner
        Tmux.tryTmux (Tmux.capture closed) >>= \case
          Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
          Left problem -> fail ("closed handle returned an unexpected error: " <> show problem)
          Right _ -> fail "the inner handle remained open after its scope"
        Tmux.capture outer
    putStrLn "independent handles: verified"
    putStrLn "closed inner handle: rejected"
    putStrLn $ "outer capture panes: " <> show (length (Tmux.panes snapshot))
    forM_ (Tmux.panes snapshot) $ \pane -> do
      window <- either (fail . show) pure (Tmux.lookupWindow snapshot pane.window)
      putStrLn $ "detached pane " <> Text.unpack (Tmux.renderPaneId (Tmux.paneId pane.ref))
        <> " belongs to " <> Text.unpack (Tmux.renderWindowId (Tmux.windowId window.ref))
  _ -> die "Usage: shared-runtime SOCKET TMUX_EXECUTABLE"
