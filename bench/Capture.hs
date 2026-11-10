-- | Measure complete public capture; fixture setup stays outside this process.
module Main (main) where

import Control.Monad (forM_)
import Data.List (intercalate)
import GHC.Clock (getMonotonicTimeNSec)
import LibTmux qualified as Tmux
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [socketArgument, executableArgument, sampleArgument]
      | Just samples <- readMaybe @Int sampleArgument, samples >= 1, samples <= 50 -> do
          socket <- Path.encodeFS socketArgument
          executable <- Path.encodeFS executableArgument
          let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
          Tmux.withServer config $ \server -> do
            putStrLn "iteration,elapsed_ns,haskell_cpu_ps,capture_ns,sessions,windows,panes,window_links,pane_occurrences"
            forM_ [1 .. samples] $ \iteration -> do
              cpuBefore <- getCPUTime
              before <- getMonotonicTimeNSec
              snapshot <- Tmux.capture server
              after <- getMonotonicTimeNSec
              cpuAfter <- getCPUTime
              interval <- maybe (die "live capture returned no acquisition interval") pure
                (Tmux.captureInterval snapshot)
              let captureTime = interval.finishedNanoseconds - interval.startedNanoseconds
                  values =
                    [ toInteger iteration, toInteger (after - before), cpuAfter - cpuBefore
                    , toInteger captureTime, toInteger (length (Tmux.sessions snapshot))
                    , toInteger (length (Tmux.windows snapshot)), toInteger (length (Tmux.panes snapshot))
                    , toInteger (length (Tmux.windowLinks snapshot))
                    , toInteger (length (Tmux.paneOccurrences snapshot))
                    ]
              putStrLn (intercalate "," (map show values))
    _ -> die "Usage: capture benchmark SOCKET TMUX_EXECUTABLE SAMPLES (1..50)"
