{-# LANGUAGE LambdaCase #-}
-- | Borrowed control client and bounded delivery over an existing native pool.
module LibTmux.Internal.Control
  ( Control, ControlOptions (..), defaultControlOptions, ControlEvent (..)
  , ControlEnd (..), ControlError (..), readControlEvent, pollControlEvent
  , withControlClient, withControlClientUsing
  , ControlRecovery, controlRecoveries, controlRetired, resumeControlCleanup
  ) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext)
import Control.Exception.Context qualified as Context
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text.Encoding qualified as Utf8
import LibTmux.Id (WindowId, parseWindowId)
import LibTmux.Internal.ControlFrames qualified as F
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Scope (operational)
import System.Timeout (timeout)

-- | Set the maximum number of queued events and whether to receive native
-- pane output notifications. The default queue holds 32 events.
data ControlOptions = ControlOptions
  { eventCapacity :: !Int
  , includePaneOutput :: !Bool
  }
  deriving stock (Eq, Show)

-- | Observe structural notifications with a 32-event queue.
defaultControlOptions :: ControlOptions
defaultControlOptions = ControlOptions 32 False

-- | Rename events identify the physical window and carry tmux's serialized
-- name. Other notifications and unsolicited text retain their native bytes.
data ControlEvent
  = WindowRenamed !WindowId !ByteString
  | ControlNotification !ByteString
  | UnframedOutput !ByteString
  deriving stock (Eq)

-- | A terminal result. Pending events are delivered before this result.
data ControlEnd
  = ControlClosed
  | ControlExited !ByteString
  | ControlOverflow
  | ControlFramingFailed
  | ControlClientLost
  deriving stock (Eq, Show)

-- | Opening or retiring the client failed. A cleanup failure can carry a
-- 'ControlRecovery' in its exception context.
data ControlError
  = InvalidControlCapacity !Int
  | ControlAttachRejected
  | ControlAttachTimedOut
  | ControlSessionMismatch
  | ControlAttachEnded !ControlEnd
  | ControlCleanupIncomplete
  deriving stock (Eq, Show)

instance Exception ControlError

data Control = Control !(TBQueue ControlEvent) !(TVar (Maybe ControlEnd))

-- | Wait for one queued event or the terminal state. Compose this STM action
-- with application events or an application deadline.
readControlEvent :: Control -> STM (Either ControlEnd ControlEvent)
readControlEvent (Control queue ended) = tryReadTBQueue queue >>= \case
  Just event -> pure (Right event)
  Nothing -> readTVar ended >>= maybe retry (pure . Left)

-- | Read an available result without waiting.
pollControlEvent :: Control -> STM (Maybe (Either ControlEnd ControlEvent))
pollControlEvent control = (Just <$> readControlEvent control) `orElse` pure Nothing

data Attachment = AwaitingReply | AwaitingSession | Attached

data ControlRecovery = ControlRecovery !P.Pool !P.Ticket !Int

instance Show ControlRecovery where
  show _ = "ControlRecovery"

instance ExceptionAnnotation ControlRecovery

-- | Find a retained control client after interrupted or incomplete cleanup.
controlRecoveries :: ExceptionContext -> [ControlRecovery]
controlRecoveries = Context.getExceptionAnnotations

-- | Inspect whether the original native client and its reader retired.
controlRetired :: ControlRecovery -> STM Bool
controlRetired (ControlRecovery pool ticket _) = P.ticketRetired pool ticket

-- | Resume cleanup of the original client. Returns true after its owned
-- resources retire.
resumeControlCleanup :: ControlRecovery -> IO Bool
resumeControlCleanup owner@(ControlRecovery pool ticket duration) = do
  P.abort ticket
  P.resumeCleanup pool ticket
  result <- timeout duration (atomically (controlRetired owner >>= check))
  pure (result == Just ())

withControlClient :: P.Pool -> N.Spec -> Int -> ByteString -> ControlOptions -> (Control -> IO a) -> IO a
withControlClient = withControlClientUsing P.defaultHooks 1000000

withControlClientUsing :: P.Hooks -> Int -> P.Pool -> N.Spec -> Int -> ByteString
  -> ControlOptions -> (Control -> IO a) -> IO a
withControlClientUsing hooks cleanupDuration pool spec duration session options action = mask $ \restore -> do
  let capacity = options.eventCapacity
  when (capacity < 1 || capacity > 128) (throwIO (InvalidControlCapacity capacity))
  queue <- newTBQueueIO (fromIntegral capacity)
  ended <- newTVarIO Nothing
  attachment <- newTVarIO AwaitingReply
  ready <- newEmptyTMVarIO
  decoder <- newIORef F.newDecoder
  let control = Control queue ended
      terminal reason = do
        current <- readTVar ended
        case current of
          Just _ -> pure ()
          Nothing -> writeTVar ended (Just reason)
        void (tryPutTMVar ready (Left (ControlAttachEnded reason)))
      reject reason = void (tryPutTMVar ready (Left reason))
      deliver frame = do
        decision <- atomically $ readTVar ended >>= \case
          Just _ -> pure True
          Nothing -> do
            phase <- readTVar attachment
            case (phase, frame) of
              (_, F.Exit reason) -> terminal (ControlExited reason) >> pure True
              (AwaitingReply, F.Reply F.ReplyRejected _) -> reject ControlAttachRejected >> pure False
              (AwaitingReply, F.Reply F.ReplySucceeded stamp) | " 0" `Bytes.isSuffixOf` stamp ->
                writeTVar attachment AwaitingSession >> pure True
              (AwaitingSession, F.Notification line)
                | Just selected <- Bytes.stripPrefix "%session-changed " line ->
                    if Bytes.takeWhile (/= 32) selected == session then do
                      writeTVar attachment Attached
                      putTMVar ready (Right ())
                      pure True
                    else reject ControlSessionMismatch >> pure False
              (Attached, F.Notification line) -> enqueue queue (notification line) terminal
              (Attached, F.Unframed line) -> enqueue queue (UnframedOutput line) terminal
              _ -> pure True
        unless decision (throwIO StopReader)
      receive chunk = do
        previous <- readIORef decoder
        case F.feed previous chunk of
          Left _ -> atomically (terminal ControlFramingFailed) >> throwIO StopReader
          Right (next, frames) -> do
            writeIORef decoder next
            mapM_ deliver frames
      -- A partial line can have one allocation per byte. Reserve space for
      -- its pieces as well as the largest allowed queued notification bodies.
      allowance = fromIntegral (128 * F.maxLineBytes + capacity * (F.maxLineBytes + 128))
  ticket <- operational (P.submitStreaming hooks pool spec allowance receive)
  let owner = ControlRecovery pool ticket cleanupDuration
      watch = do
        completed <- try @SomeException (P.await ticket)
        current <- readIORef decoder
        case completed of
          Left problem | Just (_ :: SomeAsyncException) <- fromException problem -> throwIO problem
          Right _ | Left _ <- F.endOfInput current -> atomically (terminal ControlFramingFailed)
          _ -> atomically (terminal ControlClientLost)
      body = do
        attached <- timeout duration (atomically (readTMVar ready))
        maybe (throwIO ControlAttachTimedOut) (either throwIO pure) attached
        action control
  result <- tryWithContext @SomeException (withAsync watch (\_ -> restore body))
  atomically $ do
    terminal ControlClosed
    void (flushTBQueue queue)
  retire owner result

data StopReader = StopReader
  deriving stock (Show)
instance Exception StopReader

retire :: ControlRecovery -> Either (ExceptionWithContext SomeException) a -> IO a
retire owner result = do
  cleaned <- tryWithContext @SomeException (resumeControlCleanup owner)
  let own context = Context.addExceptionAnnotation owner context
  case (result, cleaned) of
    (Right value, Right True) -> pure value
    (Left original, Right True) -> rethrowIO original
    (Left (ExceptionWithContext context problem), _) ->
      rethrowIO (ExceptionWithContext (own context) problem)
    (Right _, Left (ExceptionWithContext context problem)) ->
      rethrowIO (ExceptionWithContext (own context) problem)
    (Right _, Right False) -> annotateIO owner (throwIO ControlCleanupIncomplete)

enqueue :: TBQueue ControlEvent -> ControlEvent -> (ControlEnd -> STM ()) -> STM Bool
enqueue queue event terminal = do
  full <- isFullTBQueue queue
  if full then terminal ControlOverflow >> pure False
  else writeTBQueue queue event >> pure True

notification :: ByteString -> ControlEvent
notification line = case Bytes.stripPrefix "%window-renamed " line of
  Just arguments
    | let (nativeId, label) = Bytes.break (== 32) arguments
    , not (Bytes.null label)
    , Right text <- Utf8.decodeUtf8' nativeId
    , Right ident <- parseWindowId text -> WindowRenamed ident (Bytes.drop 1 label)
  _ -> ControlNotification line
