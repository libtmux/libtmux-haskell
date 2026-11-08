-- | Acquisition of detached physical graphs and the finite Snapshot profile.
--
-- 'captureSnapshot' includes daemon metadata and attached clients; 'captureGraph'
-- acquires only physical entities and links. Read failures and cancellation
-- can leave logical
-- uncertainty in 'R.inspect'; the caller must retain the Runtime and inspect
-- those handles. Public recovery and Server scope policies remain unfinished.
module LibTmux.Internal.Capture
  ( CapturedGraph, CapturedSnapshot, CaptureError (..), captureGraph, captureGraphWith, captureSnapshot ) where

import Control.DeepSeq (NFData, force)
import Control.Exception (Exception, Handler (..), catches, evaluate, mask, onException, throwIO)
import Control.Monad (forM, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Graph qualified as Session (Session (..))
import LibTmux.Internal.Graph qualified as Window (Window (..))
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.SocketPin (pinGeneration)
import LibTmux.Internal.Topology qualified as T
import System.Timeout (timeout)

type CapturedGraph = (Word64, Word64, G.EntityGraph)
type CapturedSnapshot = (Word64, Word64, G.Snapshot)

data CaptureError
  = CaptureChanged | CaptureDeadline | InvalidCaptureDeadline !Int
  | CaptureByteLimit !Integer | InvalidCapturedField !Field.FieldError
  | CaptureReadUnavailable !S.Outcome
  deriving stock (Eq, Show)
instance Exception CaptureError

captureGraph :: R.Runtime -> R.Client -> ByteString -> Int -> IO CapturedGraph
captureGraph runtime client executable duration = withinDeadline duration $ \deadline -> do
  left <- remaining deadline
  owned runtime (R.readGraphWith P.defaultHooks left runtime client executable)

captureSnapshot :: R.Runtime -> R.Client -> ByteString -> Int -> IO CapturedSnapshot
captureSnapshot runtime client executable duration = withinDeadline duration $ \deadline -> do
  left <- remaining deadline
  owned runtime (R.readSnapshotWith P.defaultHooks left runtime client executable)

-- | Serial comparison path with a checkpoint before its final topology read.
-- The tagged default above does not use these scalar hydration boundaries.
captureGraphWith :: IO () -> R.Runtime -> R.Client -> ByteString -> Int -> IO CapturedGraph
captureGraphWith checkpoint runtime client executable duration =
  withinDeadline duration (\deadline -> R.withCaptureBudget runtime (attempt deadline 2))
  where
    generation = pinGeneration (R.clientPin client)
    attempt :: Word64 -> Int -> IO G.EntityGraph
    attempt deadline tries = oneAttempt deadline `catches`
      [ Handler $ \problem -> case problem of
          CaptureChanged -> retry deadline tries
          _ -> throwIO problem
      , Handler $ \problem -> case problem of
          T.TopologyGraphError _ -> retry deadline tries
          _ -> throwIO problem
      , Handler $ \problem -> case problem of
          R.InvalidEntityReceipt -> retry deadline tries
          _ -> throwIO problem
      ]
    retry deadline tries
      | tries > 1 = attempt deadline (tries - 1)
      | otherwise = throwIO CaptureChanged
    oneAttempt deadline = do
      retained <- newIORef 0
      let charge amount = do
            old <- readIORef retained
            let total = old + amount
            when (total > 64 * 1024 * 1024) (throwIO (CaptureByteLimit total))
            writeIORef retained total
          topology = do
            left <- remaining deadline
            bytes <- owned runtime (R.readTopologyWith P.defaultHooks left runtime client executable R.ScalarRead)
            charge (4 * toInteger (Bytes.length bytes))
            graph <- either throwIO pure (T.decodeTopology generation bytes)
            -- Both topology graphs coexist during validation. Reserve metadata
            -- conservatively as well as wire and decoded payloads.
            charge (1024 * toInteger (length (G.graphSessions graph) + length (G.graphWindows graph)
              + length (G.graphPanes graph) + length (G.graphLinks graph)))
            pure graph
          scalar field = do
            left <- remaining deadline
            bytes <- owned runtime (R.readEntityFieldWith field P.defaultHooks left runtime client executable R.ScalarRead)
            charge (4 * toInteger (Bytes.length bytes))
            pure bytes
          decoded :: Field.Field row value -> R.EntityField -> IO value
          decoded field target = do
            bytes <- scalar target
            either (throwIO . InvalidCapturedField) pure (Field.decodeField field bytes)
      before <- topology
      sessions <- forM (G.graphSessions before) $ \row -> do
        name <- decoded Field.SessionName (R.SessionName (Field.project Field.SessionId row))
        pure row {Session.name = name}
      windows <- forM (G.graphWindows before) $ \row -> do
        name <- decoded Field.WindowName (R.WindowName (Field.project Field.WindowId row))
        pure row {Window.name = name}
      panes <- forM (G.graphPanes before) $ \row -> do
        let ident = Field.project Field.PaneId row
        title <- decoded Field.PaneTitle (R.PaneTitle ident)
        command <- decoded Field.PaneCommand (R.PaneCommand ident)
        path <- decoded Field.PanePath (R.PanePath ident)
        pure row {G.title = title, G.currentCommand = command, G.currentPath = path}
      checkpoint
      after <- topology
      when (before /= after) (throwIO CaptureChanged)
      graph <- either (const (throwIO CaptureChanged)) pure
        (G.assembleEntityGraph generation sessions windows panes (G.graphLinks before))
      evaluate (force graph)

withinDeadline :: NFData value => Int -> (Word64 -> IO value) -> IO (Word64, Word64, value)
withinDeadline duration action = do
  when (duration < 1 || duration > 10000000) (throwIO (InvalidCaptureDeadline duration))
  started <- getMonotonicTimeNSec
  let delta = fromIntegral duration * 1000
  when (started > maxBound - delta) (throwIO R.ReadClockOverflow)
  let deadline = started + delta
  left <- remaining deadline
  completed <- timeout left (action deadline >>= evaluate . force)
  graph <- maybe (throwIO CaptureDeadline) pure completed
  ended <- getMonotonicTimeNSec
  when (ended >= deadline) (throwIO CaptureDeadline)
  pure (started, ended, graph)

owned :: R.Runtime -> IO (R.Request value) -> IO value
owned runtime start = mask $ \restore -> do
  request <- start
  response <- restore (R.awaitRead request) `onException` R.cancelRead runtime request
  case response of
    R.ReadValue value -> pure value
    R.ReadUnavailable _ (Just problem) -> throwIO problem
    R.ReadUnavailable outcome Nothing -> throwIO (CaptureReadUnavailable outcome)

remaining :: Word64 -> IO Int
remaining deadline = do
  now <- getMonotonicTimeNSec
  when (now >= deadline) (throwIO CaptureDeadline)
  pure (fromIntegral ((deadline - now + 999) `div` 1000))
