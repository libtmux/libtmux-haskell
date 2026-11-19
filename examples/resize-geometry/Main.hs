{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Request absolute geometry and observe the resulting cells.
module Main (main) where

import Control.Exception (ExceptionWithContext (..), bracket, rethrowIO)
import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty (..))
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (die)
import System.OsString.Posix qualified as Os

main :: IO ()
main = do
  columns <- dimension 120
  rows <- dimension 60
  side <- dimension 30
  lower <- dimension 20
  paneWidth <- dimension 50
  paneHeight <- dimension 10
  windowWidth <- dimension 100
  windowHeight <- dimension 40
  finalWidth <- dimension 80
  oversized <- dimension 10001
  let process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
      options = Creation.defaultSessionOptions
        {Creation.width = Just columns, Creation.height = Just rows, Creation.process = process}
  result <- Tmux.tryTmux $ Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    before <- Tmux.capture server
    bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created -> do
      let slot = Creation.WindowSlot created.session created.windowIndex
      _ <- Tmux.splitPane server slot created.pane Creation.defaultSplitOptions
        {Creation.direction = Creation.LeftRight, Creation.size = Creation.SplitCells side,
          Creation.splitProcess = process}
      _ <- Tmux.splitPane server slot created.pane Creation.defaultSplitOptions
        {Creation.size = Creation.SplitCells lower, Creation.splitProcess = process}
      forM_ [("pane width", Tmux.ResizeWidth paneWidth), ("pane height", Tmux.ResizeHeight paneHeight),
             ("pane both", Tmux.ResizeBoth paneWidth lower)] $ \(label, size) -> do
        Tmux.resizePane server created.pane size
        fresh <- Tmux.capture server
        pane <- require (Tmux.lookupPane fresh created.pane)
        putStrLn $ label <> ": " <> show (Tmux.dimensionValue pane.width, Tmux.dimensionValue pane.height)
      forM_ [("window width", Tmux.ResizeWidth windowWidth), ("window height", Tmux.ResizeHeight windowHeight),
             ("window both", Tmux.ResizeBoth finalWidth side)] $ \(label, size) -> do
        Tmux.resizeWindow server created.window size
        fresh <- Tmux.capture server
        window <- require (Tmux.lookupWindow fresh created.window)
        putStrLn $ label <> ": " <> show (Tmux.dimensionValue window.width, Tmux.dimensionValue window.height)
      invalid <- Tmux.tryTmux (Tmux.resizePane server created.pane (Tmux.ResizeBoth paneWidth oversized))
      refused <- case invalid of
        Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument (Tmux.InvalidOperand "pane.height" _))) ->
          pure True
        Left problem -> rethrowIO problem
        Right () -> die "Oversized resize unexpectedly succeeded"
      after <- Tmux.capture server
      let preserved old = case Tmux.lookupWindow after old.ref of
            Right current -> (current.width, current.height) == (old.width, old.height)
            Left _ -> False
      putStrLn $ "invalid size refused: " <> show refused
      putStrLn $ "bystander preserved: " <> show (all preserved (Tmux.windows before))
    remaining <- Tmux.capture server
    putStrLn $ "original sessions after cleanup: " <>
      show (map (.ref) (Tmux.sessions remaining) == map (.ref) (Tmux.sessions before))
  either rethrowIO pure result

dimension :: Integer -> IO Tmux.Dimension
dimension = require . Tmux.mkDimension

require :: Show problem => Either problem a -> IO a
require = either (die . show) pure
