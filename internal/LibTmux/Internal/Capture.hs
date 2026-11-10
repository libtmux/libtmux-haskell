-- | Acquisition of detached physical graphs and the finite Snapshot profile.
--
-- 'captureSnapshot' includes daemon metadata and attached clients; 'captureGraph'
-- acquires only physical entities and links. Read failures and cancellation
-- can leave logical uncertainty. t'CaptureRecovery' in the exception context
-- retains the exact read and its recovery owner, without retaining its result.
-- "LibTmux.Server" owns the public scope and cleanup policy.
module LibTmux.Internal.Capture
  ( CapturedGraph, CapturedSnapshot, CaptureError (..), captureGraph, captureGraphWith, captureSnapshot, captureSnapshotWith
  , CaptureRecovery, captureRecoveries, recoveryReceipt, inspectRecovery, resumeRecovery, detachRecovery
  ) where

import Control.Concurrent.STM (STM)
import Control.DeepSeq (NFData, force)
import Control.Exception (Exception, ExceptionWithContext (..), Handler (..), SomeException,
  catchNoPropagate, catches, evaluate, mask, onException, rethrowIO, someExceptionContext, throwIO)
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Control.Monad (forM, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.Maybe (listToMaybe)
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

-- | A reachable owner for one failed or cancelled capture. The receipt holds
-- metadata only; the Runtime retains any remaining native and logical owners.
data CaptureRecovery = CaptureRecovery !R.Runtime !R.ServerHandle !R.ReadReceipt
instance Show CaptureRecovery where
  showsPrec precedence (CaptureRecovery _ _ receipt) =
    showParen (precedence > 10) (showString "CaptureRecovery " . shows receipt)
instance ExceptionAnnotation CaptureRecovery

captureRecoveries :: SomeException -> [CaptureRecovery]
captureRecoveries = Context.getExceptionAnnotations . someExceptionContext

recoveryReceipt :: CaptureRecovery -> R.ReadReceipt
recoveryReceipt (CaptureRecovery _ _ receipt) = receipt

inspectRecovery :: CaptureRecovery -> STM R.ReadRecovery
inspectRecovery (CaptureRecovery runtime client receipt) = R.inspectReceipt runtime client receipt

-- | Resume only existing cleanup, leaving Runtime admission open. Never retry
-- the tmux read; a new capture is a separately requested observation.
resumeRecovery :: CaptureRecovery -> IO ()
resumeRecovery (CaptureRecovery runtime client receipt) = R.resumeReceipt runtime client receipt

-- | Explicitly release logical uncertainty without releasing native owners.
detachRecovery :: CaptureRecovery -> STM Bool
detachRecovery (CaptureRecovery runtime client receipt) = R.detachReceipt runtime client receipt

captureGraph :: R.Runtime -> R.ServerHandle -> ByteString -> Int -> IO CapturedGraph
captureGraph runtime client executable duration = withinDeadline runtime client duration $ \receipt deadline -> do
  left <- remaining deadline
  owned runtime receipt (R.readGraphWith P.defaultHooks left runtime client executable)

captureSnapshot :: R.Runtime -> R.ServerHandle -> ByteString -> Int -> IO CapturedSnapshot
captureSnapshot = captureSnapshotWith P.defaultHooks

-- | Use the native process checkpoints while retaining capture correlation
-- across worker handoff, cancellation and conversion of a deadline failure.
captureSnapshotWith :: P.Hooks -> R.Runtime -> R.ServerHandle -> ByteString -> Int -> IO CapturedSnapshot
captureSnapshotWith hooks runtime client executable duration = withinDeadline runtime client duration $ \receipt deadline -> do
  left <- remaining deadline
  owned runtime receipt (R.readSnapshotWith hooks left runtime client executable)

-- | Serial comparison path with a checkpoint before its final topology read.
-- The tagged default above does not use these scalar hydration boundaries.
captureGraphWith :: IO () -> R.Runtime -> R.ServerHandle -> ByteString -> Int -> IO CapturedGraph
captureGraphWith checkpoint runtime client executable duration =
  withinDeadline runtime client duration (\receipt deadline -> R.withCaptureBudget runtime (attempt receipt deadline 2))
  where
    generation = pinGeneration (R.serverPin client)
    attempt :: IORef (Maybe R.ReadReceipt) -> Word64 -> Int -> IO G.EntityGraph
    attempt receipt deadline tries = oneAttempt receipt deadline `catches`
      [ Handler $ \problem -> case problem of
          CaptureChanged -> retry receipt deadline tries
          _ -> throwIO problem
      , Handler $ \problem -> case problem of
          T.TopologyGraphError _ -> retry receipt deadline tries
          _ -> throwIO problem
      , Handler $ \problem -> case problem of
          R.InvalidEntityReceipt -> retry receipt deadline tries
          _ -> throwIO problem
      ]
    retry receipt deadline tries
      | tries > 1 = attempt receipt deadline (tries - 1)
      | otherwise = throwIO CaptureChanged
    oneAttempt receipt deadline = do
      retained <- newIORef 0
      let charge amount = do
            old <- readIORef retained
            let total = old + amount
            when (total > 64 * 1024 * 1024) (throwIO (CaptureByteLimit total))
            writeIORef retained total
          topology = do
            left <- remaining deadline
            bytes <- owned runtime receipt (R.readTopologyWith P.defaultHooks left runtime client executable R.ScalarRead)
            charge (4 * toInteger (Bytes.length bytes))
            graph <- either throwIO pure (T.decodeTopology generation bytes)
            -- Both topology graphs coexist during validation. Reserve metadata
            -- conservatively as well as wire and decoded payloads.
            charge (1024 * toInteger (length (G.graphSessions graph) + length (G.graphWindows graph)
              + length (G.graphPanes graph) + length (G.graphLinks graph)))
            pure graph
          scalar field = do
            left <- remaining deadline
            bytes <- owned runtime receipt (R.readEntityFieldWith field P.defaultHooks left runtime client executable R.ScalarRead)
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

withinDeadline :: NFData value => R.Runtime -> R.ServerHandle -> Int
  -> (IORef (Maybe R.ReadReceipt) -> Word64 -> IO value) -> IO (Word64, Word64, value)
withinDeadline runtime client duration action = mask $ \restore -> do
  when (duration < 1 || duration > 10000000) (throwIO (InvalidCaptureDeadline duration))
  receipt <- newIORef Nothing
  let annotate (ExceptionWithContext context (problem :: SomeException)) = do
        current <- readIORef receipt
        let selected = case current of
              Just value -> Just value
              Nothing -> listToMaybe (Context.getExceptionAnnotations @R.ReadReceipt context)
            annotated = case selected of
              Nothing -> context
              Just !value ->
                let !recovery = CaptureRecovery runtime client value
                in Context.addExceptionAnnotation recovery context
        rethrowIO (ExceptionWithContext annotated problem)
  catchNoPropagate (restore (timed receipt)) annotate
  where
    timed receipt = do
      started <- getMonotonicTimeNSec
      let delta = fromIntegral duration * 1000
      when (started > maxBound - delta) (throwIO R.ReadClockOverflow)
      let deadline = started + delta
      left <- remaining deadline
      completed <- timeout left (action receipt deadline >>= evaluate . force)
      graph <- maybe (throwIO CaptureDeadline) pure completed
      ended <- getMonotonicTimeNSec
      when (ended >= deadline) (throwIO CaptureDeadline)
      pure (started, ended, graph)

owned :: R.Runtime -> IORef (Maybe R.ReadReceipt) -> IO (R.Request value) -> IO value
owned runtime receipt start = mask $ \restore -> do
  writeIORef receipt Nothing
  request <- catchNoPropagate start $ \problem@(ExceptionWithContext context (_ :: SomeException)) -> do
    -- System.Timeout consumes its private exception. Copy correlation before
    -- that conversion, including when start never returns a Request.
    case Context.getExceptionAnnotations @R.ReadReceipt context of
      current : _ -> current `seq` writeIORef receipt (Just current)
      [] -> pure ()
    rethrowIO problem
  let !current = R.readReceipt request
  writeIORef receipt (Just current)
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
