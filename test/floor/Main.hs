module Main (main) where

import Control.Exception (ExceptionWithContext (..))
import Control.Monad (forM_, unless, when)
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import System.Environment (getEnv, lookupEnv)
import System.Exit (die)
import System.OsString.Posix qualified as Os

main :: IO ()
main = do
  sandbox <- lookupEnv "LIBTMUX_TEST_SANDBOX"
  temporary <- lookupEnv "TMUX_TMPDIR"
  unless (sandbox /= Nothing && sandbox == temporary)
    (die "floor refusal requires an owned LIBTMUX_TEST_SANDBOX")
  socket <- getEnv "LIBTMUX_TEST_SOCKET"
  executable <- getEnv "LIBTMUX_TEST_TMUX"
  expected <- getEnv "LIBTMUX_TEST_DAEMON_VERSION" >>= either (fail . show) pure . Tmux.parseVersion . Text.pack
  let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack socket)))
        {Tmux.executable = Os.fromBytestring (Bytes.pack executable), Tmux.captureTimeout = 0.2}
  forM_ [False, True] $ \shared -> do
    entered <- newIORef False
    let callback _ = writeIORef entered True
        action = if shared
          then Tmux.withRuntime (\runtime -> Tmux.withServerIn runtime config callback)
          else Tmux.withServer config callback
    result <- Tmux.tryTmux action
    called <- readIORef entered
    when called (die "below-floor daemon entered a Server callback")
    case result of
      Left (ExceptionWithContext _ (Tmux.UnsupportedTmuxVersion (Tmux.UnsupportedVersion actual)))
        | actual == expected -> pure ()
      Left (ExceptionWithContext _ Tmux.IncompatibleTmuxClientProtocol)
        | Tmux.renderVersion expected == "3.0a" -> pure ()
      other -> die ("expected the actual daemon's floor refusal, got " <> show other)
  putStrLn ("refused tmux " <> Text.unpack (Tmux.renderVersion expected))
