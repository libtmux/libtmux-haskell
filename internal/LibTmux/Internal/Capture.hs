-- | Acquisition of a validated, detached physical entity graph.
--
-- This private slice observes sessions, windows and panes. It does not acquire
-- observed clients. Framed read failures and cancellation can leave logical
-- uncertainty in 'R.inspect'; the caller must retain the Runtime and inspect
-- those handles. Public recovery and scoped Client policies remain unfinished.
module LibTmux.Internal.Capture
  ( CapturedGraph, CaptureError (..), captureGraph, captureGraphWith ) where

import Control.DeepSeq (force)
import Control.Exception (Exception, Handler (..), catches, evaluate, mask, onException, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.Text (Text)
import Data.Text.Encoding qualified as Utf8
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.SocketPin (pinGeneration)
import LibTmux.Internal.Topology qualified as T
import System.Timeout (timeout)

type CapturedGraph = (Word64, Word64, G.EntityGraph)

data CaptureError
  = CaptureChanged | CaptureDeadline | InvalidCaptureDeadline !Int
  | CaptureByteLimit !Integer | InvalidFieldEncoding !R.EntityField
  | CaptureReadUnavailable !S.Outcome
  deriving stock (Eq, Show)
instance Exception CaptureError

captureGraph :: R.Runtime -> R.Client -> ByteString -> Int -> IO CapturedGraph
captureGraph = captureGraphWith (pure ())

captureGraphWith :: IO () -> R.Runtime -> R.Client -> ByteString -> Int -> IO CapturedGraph
captureGraphWith checkpoint runtime client executable duration = do
  when (duration < 1 || duration > 10000000) (throwIO (InvalidCaptureDeadline duration))
  started <- getMonotonicTimeNSec
  let delta = fromIntegral duration * 1000
  when (started > maxBound - delta) (throwIO R.ReadClockOverflow)
  let deadline = started + delta
  R.withCaptureBudget runtime $ do
    left <- remaining deadline
    completed <- timeout left (attempt deadline 2)
    graph <- maybe (throwIO CaptureDeadline) pure completed
    ended <- getMonotonicTimeNSec
    when (ended >= deadline) (throwIO CaptureDeadline)
    pure (started, ended, graph)
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
            bytes <- owned (R.readTopologyWith P.defaultHooks left runtime client executable R.ScalarRead)
            charge (4 * toInteger (Bytes.length bytes))
            graph <- either throwIO pure (T.decodeTopology generation bytes)
            -- Both topology graphs coexist during validation. Reserve metadata
            -- conservatively as well as wire and decoded payloads.
            charge (1024 * toInteger (length (G.graphSessions graph) + length (G.graphWindows graph)
              + length (G.graphPanes graph) + length (G.graphLinks graph)))
            pure graph
          scalar field = do
            left <- remaining deadline
            bytes <- owned (R.readEntityFieldWith field P.defaultHooks left runtime client executable R.ScalarRead)
            charge (4 * toInteger (Bytes.length bytes))
            pure bytes
          text field = do
            bytes <- scalar field
            either (const (throwIO (InvalidFieldEncoding field))) (evaluate . force) (Utf8.decodeUtf8' bytes)
      before <- topology
      sessions <- mapM (hydrateSession text) (G.graphSessions before)
      windows <- mapM (hydrateWindow text) (G.graphWindows before)
      panes <- mapM (hydratePane text scalar) (G.graphPanes before)
      checkpoint
      after <- topology
      when (before /= after) (throwIO CaptureChanged)
      graph <- either (const (throwIO CaptureChanged)) pure
        (G.assembleEntityGraph generation sessions windows panes (G.graphLinks before))
      evaluate (force graph)
    owned start = mask $ \restore -> do
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

hydrateSession :: (R.EntityField -> IO Text) -> G.Session -> IO G.Session
hydrateSession text row = do
  let G.SessionRef _ ident = row.ref
  name <- text (R.SessionName ident)
  pure (G.Session row.ref name row.attached)

hydrateWindow :: (R.EntityField -> IO Text) -> G.Window -> IO G.Window
hydrateWindow text row = do
  let G.WindowRef _ ident = row.ref
  name <- text (R.WindowName ident)
  pure (G.Window row.ref name row.width row.height)

hydratePane :: (R.EntityField -> IO Text) -> (R.EntityField -> IO ByteString) -> G.Pane -> IO G.Pane
hydratePane text scalar row = do
  let G.PaneRef _ ident = row.ref
  title <- text (R.PaneTitle ident)
  command <- text (R.PaneCommand ident)
  path <- scalar (R.PanePath ident)
  pure row {G.title = title, G.currentCommand = command, G.currentPath = path}
