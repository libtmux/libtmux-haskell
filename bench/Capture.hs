-- | Build one private graph and measure capture after setup.
module Main (main) where

import Control.Monad (forM, forM_, replicateM, replicateM_, void, when)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import GHC.Clock (getMonotonicTimeNSec)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os
import Text.Read (readMaybe)

main :: IO ()
main = getArgs >>= \case
  [executableArgument, sessionArgument, windowArgument, paneArgument, sampleArgument]
    | Just counts@[sessions, windows, panes, samples] <- traverse (readMaybe @Int)
        [sessionArgument, windowArgument, paneArgument, sampleArgument]
    , all (>= 1) counts, sessions <= windows, windows <= panes, panes <= 250, samples <= 50 -> do
        executable <- Path.encodeFS executableArgument
        let config = Tmux.defaultOwnedServerConfig {Tmux.tmuxExecutable = executable}
        started <- getMonotonicTimeNSec
        Tmux.withOwnedServer config $ \server -> do
          buildGraph server sessions windows panes
          setup <- subtract started <$> getMonotonicTimeNSec
          putStrLn "iteration,elapsed_ns,haskell_cpu_ps,capture_ns,sessions,windows,panes,window_links,pane_occurrences,setup_ns"
          forM_ [1 .. samples] $ \iteration -> do
            row <- measure server iteration
            putStrLn (intercalate "," (map show (row <> [toInteger setup])))
  _ -> die "Usage: capture benchmark TMUX SESSIONS WINDOWS PANES SAMPLES"

buildGraph :: Tmux.Server -> Int -> Int -> Int -> IO ()
buildGraph server sessions windows panes = do
  alias <- either (die . show) pure (Tmux.mkWindowIndex 4)
  width <- either (die . show) pure (Tmux.mkDimension 200)
  height <- either (die . show) pure (Tmux.mkDimension 60)
  let idle = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
      sessionOptions = Creation.defaultSessionOptions
        {Creation.width = Just width, Creation.height = Just height, Creation.process = idle}
      windowOptions = Creation.defaultWindowOptions {Creation.windowProcess = idle}
      splitOptions = Creation.defaultSplitOptions
        {Creation.direction = Creation.LeftRight, Creation.splitProcess = idle}
  built <- forM (zip [0 :: Int ..] (spread windows sessions)) $ \(number, count) -> do
    created <- Tmux.createSession server sessionOptions
    when (number == 0) $
      Tmux.linkWindow server (slot created) (Creation.WindowSlot created.session alias)
    added <- replicateM (count - 1) $
      Tmux.createWindow server (Creation.NextFree created.session) windowOptions
    pure (created.session, (slot created, created.pane) : [(slot child, child.pane) | child <- added])
  let targets = concatMap snd built
  forM_ (zip targets (spread panes windows)) $ \((context, pane), count) ->
    replicateM_ (count - 1) (void (Tmux.splitPane server context pane splitOptions))
  when (sessions > 1) $
    forM_ (take 3 (zip3 [100 ..] targets (drop 1 (cycle (map fst built))))) $
      \(index, (context, _), destination) -> do
        target <- either (die . show) pure (Tmux.mkWindowIndex index)
        Tmux.linkWindow server context (Creation.WindowSlot destination target)

slot :: Creation.CreatedEntities -> Creation.WindowSlot
slot created = Creation.WindowSlot created.session created.windowIndex

spread :: Int -> Int -> [Int]
spread total parts = replicate remainder (size + 1) <> replicate (parts - remainder) size
  where (size, remainder) = total `quotRem` parts

measure :: Tmux.Server -> Int -> IO [Integer]
measure server iteration = do
  cpuBefore <- getCPUTime
  before <- getMonotonicTimeNSec
  snapshot <- Tmux.capture server
  after <- getMonotonicTimeNSec
  cpuAfter <- getCPUTime
  interval <- maybe (die "live capture returned no acquisition interval") pure
    (Tmux.captureInterval snapshot)
  let captureTime = interval.finishedNanoseconds - interval.startedNanoseconds
  pure
    [ toInteger iteration, toInteger (after - before), cpuAfter - cpuBefore
    , toInteger captureTime, toInteger (length (Tmux.sessions snapshot))
    , toInteger (length (Tmux.windows snapshot)), toInteger (length (Tmux.panes snapshot))
    , toInteger (length (Tmux.windowLinks snapshot))
    , toInteger (length (Tmux.paneOccurrences snapshot))
    ]
