{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless)
import Data.ByteString.Char8 qualified as Bytes
import LibTmux qualified as Tmux
import LibTmux.Capabilities qualified as Cap
import LibTmux.Program qualified as Program
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
    Tmux.withServer config $ \server -> do
      unless (Cap.supports (Tmux.serverCapabilities server) Cap.ManagedPrograms)
        (die "This example requires connected tmux 3.8 or newer")
      before <- Tmux.capture server
      result <- Tmux.runProgram server (settings "/bin/sh"
        ["-c", "printf '%s' \"$1\"; exit 7", "app", "literal ; $HOME"])
      require (result.programExit == Program.ProgramExited 7) "exit status changed"
      require ("literal ; $HOME" `Bytes.isPrefixOf` result.programOutput.screenBytes) "argv changed"
      putStrLn ("exit: " <> show result.programExit)
      putStrLn "literal argv: True"

      Tmux.withProgram server (settings "/bin/sh"
        ["-c", "IFS= read -r line; printf 'received:%s' \"$line\""]) $ \program -> do
          observing <- newEmptyMVar
          withAsync (try @AsyncException (putMVar observing () >> Program.waitProgram program)) $ \observer -> do
            takeMVar observing
            throwTo (asyncThreadId observer) ThreadKilled
            cancelled <- wait observer
            require (cancelled == Left ThreadKilled) "observation did not report cancellation"
          Program.sendProgramInput program "literal ; $HOME\n"
          Program.waitProgram program >>= \status -> require (status == Program.ProgramExited 0) "interactive exit changed"
          output <- Program.readProgramScreen program
          require ("received:literal ; $HOME" `Bytes.isInfixOf` output.screenBytes) "input changed"
      putStrLn "cancelled observation: True"
      putStrLn "interactive retry: True"

      entered <- newEmptyMVar
      expired <- try @Program.ProgramError (Tmux.withProgram server
        (settings "/bin/sh" ["-c", "trap '' HUP TERM; exec /bin/cat -"])
          {Program.executionTimeout = Just 0.5} $ \program ->
            putMVar entered () >> Program.waitProgram program)
      started <- tryTakeMVar entered
      require (started == Just () && expired == Left Program.ProgramTimedOut) "owning deadline did not clean up active work"
      putStrLn "owning deadline: True"
      after <- Tmux.capture server
      require (map (.ref) (Tmux.sessions before) == map (.ref) (Tmux.sessions after)
        && map (.ref) (Tmux.panes before) == map (.ref) (Tmux.panes after)) "borrowed resources changed"
      putStrLn "borrowed resources preserved: True"
  _ -> die "Usage: managed-program SOCKET TMUX_EXECUTABLE"

settings :: String -> [String] -> Program.ProgramOptions
settings file args = Program.programOptions (Os.fromBytestring (Bytes.pack file))
  (map (Os.fromBytestring . Bytes.pack) args)

require :: Bool -> String -> IO ()
require condition message = unless condition (die message)
