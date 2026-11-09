-- | Observe an existing tmux daemon through an owned Server handle.
--
-- A t'Server' represents one adoption of one endpoint. 'withServer' owns its
-- socket pin, native command clients and cleanup workers. Closing this scope
-- releases those resources; it does not send @kill-server@. The tmux noun
-- @Client@ refers to detached observations in "LibTmux.Snapshot".
--
-- 'capture' returns fully decoded, validated values. Field access and graph
-- navigation are pure. Captures use an observation interval, not an atomic
-- transaction over tmux and operating-system state.
--
-- Operational failures use t'TmuxException'. 'tryTmux' catches that type only.
-- Cancellation retains its original exception class. If bounded cleanup
-- cannot finish, 'cleanupRecoveries' retrieves the owning recovery scope
-- from the exception context. A failed callback remains the primary failure.
module LibTmux.Server
  ( -- * Open and observe
    Server, ServerConfig (..), serverConfig, withServer, capture, serverGeneration
    -- * Operational failures
  , TmuxException (..), tryTmux
    -- * Scope cleanup
  , CleanupRecovery, CleanupStatus (..), cleanupRecoveries, cleanupFailure, cleanupObservation
  , inspectCleanup, resumeCleanup, awaitCleanup, detachUnresolved
    -- * Correlated capture recovery
  , CaptureRecovery, captureRecoveries, recoveryOperation, recoveryGeneration
  , ReadRecovery (..), inspectCaptureRecovery, resumeCaptureRecovery, detachCaptureRecovery
  , Operation, Status (..), Stage (..), Outcome (..), operationStatus
  ) where

import Control.Concurrent.STM (atomically, readTVar)
import Control.DeepSeq (force)
import Control.Exception
  ( ExceptionWithContext (..), IOException, SomeAsyncException, SomeException
  , catchNoPropagate, evaluate, fromException, rethrowIO, throwIO, tryWithContext
  )
import Control.Exception.Context (ExceptionContext)
import Control.Exception.Context qualified as Context
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import Data.Type.Coercion (coerceWith, sym)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture (CaptureRecovery)
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime (ReadRecovery (..))
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler (Operation, Status (..), Stage (..), Outcome (..))
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.Scope
  ( TmuxException (..), CleanupRecovery, CleanupStatus (..)
  , cleanupFailure, cleanupObservation, inspectCleanup, resumeCleanup, awaitCleanup
  )
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Snapshot (Generation, Snapshot)
import System.Directory.OsPath qualified as Directory
import System.OsPath.Posix (PosixPath)
import System.OsPath.Posix qualified as Path
import System.OsString qualified as Platform
import System.OsString.Posix qualified as Os

-- | One pinned endpoint and connection generation. The constructor is hidden.
-- Retaining this value after 'withServer' does not keep admission open.
data Server = Server !R.Runtime !R.ServerHandle !ByteString !Int

-- | Pure configuration, checked when 'withServer' opens the handle.
-- Paths retain POSIX bytes; no text decoding or shell interpretation occurs.
data ServerConfig = ServerConfig
  { socketPath :: !PosixPath -- ^ Existing tmux socket, with an absolute trusted path.
  , executable :: !PosixPath -- ^ Executable path or a program resolved once through PATH.
  , pinDirectory :: !PosixPath -- ^ Writable trusted directory on the socket's filesystem.
  , captureTimeout :: !NominalDiffTime -- ^ Capture deadline in seconds, greater than zero and at most ten.
  }
  deriving stock (Eq, Show)

-- | Configure an existing socket, resolving @tmux@ through PATH when opened.
-- The private pin uses the socket's parent directory. The capture timeout is
-- two seconds; callers can change it before 'withServer'.
serverConfig :: PosixPath -> ServerConfig
serverConfig socket = ServerConfig socket (Os.fromBytestring "tmux") (Path.takeDirectory socket) 2

-- | Open one handle, run the callback, then perform bounded owned cleanup.
-- Cleanup never replaces a callback exception. Incomplete cleanup raises
-- 'CleanupFailed' after success, or annotates the original callback failure
-- with a reachable t'CleanupRecovery'. No daemon shutdown is requested.
withServer :: ServerConfig -> (Server -> IO a) -> IO a
withServer config action = do
  let seconds = toRational config.captureTimeout
  when (seconds <= 0 || seconds > 10) $
    throwIO (InvalidConfiguration "captureTimeout must be greater than zero and at most ten seconds")
  executable <- operational (resolveExecutable config.executable)
  runtime <- R.newRuntime P.normalFork
  Scope.runScope runtime $ do
    handle <- operational (R.adopt runtime (posixBytes config.socketPath) (posixBytes config.pinDirectory))
    action (Server runtime handle executable (fromInteger (ceiling (seconds * 1000000))))

-- | Acquire the complete baseline graph, metadata and attached clients.
-- Returned values own their data and remain usable after 'withServer' exits.
-- Capacity and acquisition failure are errors; they never become empty lists.
capture :: Server -> IO Snapshot
capture (Server runtime handle executable duration) = operational $ do
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  (started, finished, decoded) <- C.captureSnapshot runtime handle executable duration
  stamped <- either (throwIO . InvalidObservation . Text.pack . show) pure
    (G.stampSnapshot started finished decoded)
  evaluate (force stamped)

-- | The handle's opaque generation, available without contacting tmux.
serverGeneration :: Server -> Generation
serverGeneration (Server _ handle _ _) = Pin.pinGeneration (R.serverPin handle)

-- | Catch library failures with their exception context. Retain this value
-- when handling an error so cleanup and capture owners stay reachable.
-- Application exceptions and asynchronous cancellation propagate.
tryTmux :: IO a -> IO (Either (ExceptionWithContext TmuxException) a)
tryTmux = tryWithContext

-- | Cleanup owners retained by a failed or cancelled scope. The context
-- comes from 'tryTmux' or 'tryWithContext'. Inspection performs no tmux IO.
cleanupRecoveries :: ExceptionContext -> [CleanupRecovery]
cleanupRecoveries = Context.getExceptionAnnotations

-- | Relinquish one logical operation from this cleanup scope. This releases
-- no native resources and does not prove that daemon-side work completed.
detachUnresolved :: CleanupRecovery -> Operation -> IO Bool
detachUnresolved recovery = operational . Scope.detachUnresolved recovery

-- | Capture owners retained in an exception context, including cancellation.
captureRecoveries :: ExceptionContext -> [CaptureRecovery]
captureRecoveries = Context.getExceptionAnnotations

-- | Metadata-only operation identity for the failed capture.
recoveryOperation :: CaptureRecovery -> Operation
recoveryOperation = R.receiptOperation . C.recoveryReceipt

-- | Correlate the failed capture with its Server generation.
recoveryGeneration :: CaptureRecovery -> Generation
recoveryGeneration = R.receiptGeneration . C.recoveryReceipt

-- | Observe logical outcome, decoder ownership and native cleanup locally.
-- This reads runtime metadata and performs no tmux command.
inspectCaptureRecovery :: CaptureRecovery -> IO ReadRecovery
inspectCaptureRecovery = atomically . C.inspectRecovery

-- | Resume existing cleanup without dispatching the capture again.
resumeCaptureRecovery :: CaptureRecovery -> IO ()
resumeCaptureRecovery = operational . C.resumeRecovery

-- | Explicitly detach logical uncertainty while preserving native ownership.
detachCaptureRecovery :: CaptureRecovery -> IO Bool
detachCaptureRecovery = operational . atomically . C.detachRecovery

-- | Read retained operation metadata, including after its physical cleanup.
operationStatus :: Operation -> IO Status
operationStatus = atomically . S.status

resolveExecutable :: PosixPath -> IO ByteString
resolveExecutable executable = case Platform.coercionToPlatformTypes of
  Left _ -> throwIO (InvalidConfiguration "this package requires Linux POSIX paths")
  Right (_, proof) -> do
    selected <- Directory.findExecutable (coerceWith (sym proof) executable)
    path <- maybe (throwIO (InvalidConfiguration "tmux executable was not found")) Directory.makeAbsolute selected
    pure (posixBytes (coerceWith proof path))

posixBytes :: PosixPath -> ByteString
posixBytes = Bytes.pack . map (fromIntegral . fromEnum . Os.toChar) . Os.unpack

operational :: IO a -> IO a
operational action = catchNoPropagate action $ \original@(ExceptionWithContext context (problem :: SomeException)) ->
  let known = or
        [ isJust (fromException @IOException problem)
        , isJust (fromException @Pin.PinError problem)
        , isJust (fromException @R.ReadError problem)
        , isJust (fromException @C.CaptureError problem)
        , isJust (fromException @B.LimitError problem)
        , isJust (fromException @P.OwnerError problem)
        , isJust (fromException @N.Failure problem)
        , isJust (fromException @S.AdmissionError problem)
        ]
  in if known && not (isJust (fromException @SomeAsyncException problem))
       then rethrowIO (ExceptionWithContext context (OperationFailed problem))
       else rethrowIO original
