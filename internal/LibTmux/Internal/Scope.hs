-- | Exception and recovery policy for an owned Runtime scope.
module LibTmux.Internal.Scope
  ( TmuxException (..), CleanupStatus (..), CleanupRecovery
  , runScope, cleanupRecoveries, cleanupFailure, cleanupObservation, inspectCleanup, resumeCleanup
  , awaitCleanup, detachUnresolved
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Data.Maybe (catMaybes)
import Data.Text (Text)
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S

-- | Library operational failures. Context-preserving catching retains any
-- cleanup owners; the original application or cancellation exception keeps
-- its class when the callback itself failed.
data TmuxException
  = ServerClosed -- ^ Admission through the retained Server handle has closed.
  | InvalidConfiguration !Text -- ^ Configuration failed before acquisition.
  | InvalidObservation !Text -- ^ Acquired metadata failed final validation.
  | OperationFailed !SomeException -- ^ Known backend failure with its original cause.
  | CleanupFailed !CleanupStatus !(Maybe SomeException) -- ^ Cleanup remained incomplete or its worker could not start.
  deriving stock (Show)
instance Exception TmuxException

-- | Local observations of physical and logical cleanup responsibility.
-- Each inspection returns new metadata; it performs no tmux operation.
data CleanupStatus = CleanupStatus
  { complete :: !Bool -- ^ All physical owners, read workers and logical responsibility have retired.
  , pendingHandles :: !Int -- ^ Server handles still awaiting physical retirement.
  , pendingReads :: !Int -- ^ Decoder or recovery workers retaining read envelopes.
  , unresolved :: ![(S.Operation, S.Status)] -- ^ Retained logical operations with their observed status.
  , failures :: ![SomeException] -- ^ Currently observed pin, worker or cleanup-request failures.
  }
  deriving stock (Show)

-- | Reachable ownership after an incomplete or failed scope release. Keeping
-- this value retains the Runtime responsible for its remaining resources.
data CleanupRecovery = CleanupRecovery !R.Runtime !CleanupStatus !(Maybe SomeException)
instance Show CleanupRecovery where
  show _ = "CleanupRecovery"
instance ExceptionAnnotation CleanupRecovery

runScope :: R.Runtime -> IO a -> IO a
runScope runtime action = mask $ \restore -> do
  body <- tryWithContext @SomeException (restore action)
  cleanup <- tryWithContext @SomeException (R.shutdown runtime)
  case cleanup of
    Right report -> do
      let status = observed report
      if status.complete then either rethrowIO pure body else do
        let !recovery = CleanupRecovery runtime status Nothing
        case body of
          Left primary -> rethrowIO (annotated recovery primary)
          Right _ -> rethrowIO (annotated recovery
            (ExceptionWithContext mempty (toException (CleanupFailed status Nothing))))
    Left problem -> do
      status <- observed <$> atomically (R.inspect runtime)
      let ExceptionWithContext _ cause = problem
          !recovery = CleanupRecovery runtime status (Just cause)
      case body of
        Left primary -> rethrowIO (annotated recovery primary)
        Right _ -> throwCleanup recovery problem

cleanupRecoveries :: SomeException -> [CleanupRecovery]
cleanupRecoveries = Context.getExceptionAnnotations . someExceptionContext

-- | Exception that interrupted the original cleanup attempt, when there was
-- one. Pending ownership alone need not have an associated exception.
cleanupFailure :: CleanupRecovery -> Maybe SomeException
cleanupFailure (CleanupRecovery _ _ problem) = problem

-- | The cleanup metadata recorded when this recovery owner was attached.
cleanupObservation :: CleanupRecovery -> CleanupStatus
cleanupObservation (CleanupRecovery _ status _) = status

-- | Inspect current owned cleanup and logical uncertainty without tmux IO.
inspectCleanup :: CleanupRecovery -> IO CleanupStatus
inspectCleanup (CleanupRecovery runtime _ _) = observed <$> atomically (R.inspect runtime)

-- | Retry bounded owned cleanup. An incomplete result retains this owner;
-- the operation does not retry a tmux command or release logical uncertainty.
resumeCleanup :: CleanupRecovery -> IO CleanupStatus
resumeCleanup recovery@(CleanupRecovery runtime _ _) =
  recoverCleanup recovery (R.shutdown runtime)

-- | Wait for physical cleanup without a deadline, then inspect logical debt.
-- Cancellation or failure preserves an annotated cleanup owner. Use
-- 'resumeCleanup' when the caller requires a bounded attempt.
awaitCleanup :: CleanupRecovery -> IO CleanupStatus
awaitCleanup recovery@(CleanupRecovery runtime _ _) = recoverCleanup recovery $ do
  R.awaitCleanup runtime
  atomically (R.inspect runtime)

detachUnresolved :: CleanupRecovery -> S.Operation -> IO Bool
detachUnresolved (CleanupRecovery runtime _ _) operation = atomically (R.detachOperation runtime operation)

annotated :: CleanupRecovery -> ExceptionWithContext SomeException -> ExceptionWithContext SomeException
annotated recovery (ExceptionWithContext context problem) =
  ExceptionWithContext (Context.addExceptionAnnotation recovery context) problem

throwCleanup :: CleanupRecovery -> ExceptionWithContext SomeException -> IO a
throwCleanup recovery problem@(ExceptionWithContext context cause) =
  case fromException @SomeAsyncException cause of
    Just _ -> rethrowIO (annotated recovery problem)
    Nothing -> rethrowIO (annotated recovery (ExceptionWithContext context
      (toException (CleanupFailed (cleanupObservation recovery) (Just cause)))))

recoverCleanup :: CleanupRecovery -> IO R.Report -> IO CleanupStatus
recoverCleanup (CleanupRecovery runtime _ _) action =
  catchNoPropagate (observed <$> action) $ \problem@(ExceptionWithContext _ (cause :: SomeException)) -> do
    status <- observed <$> atomically (R.inspect runtime)
    let !recovery = CleanupRecovery runtime status (Just cause)
    throwCleanup recovery problem

observed :: R.Report -> CleanupStatus
observed report =
  let failures = map snd report.closeFailures
        <> [problem | (_, P.PinCleanupFailed problem) <- report.pending]
        <> catMaybes (map snd report.readWorkers)
      complete = null report.pending && null report.readWorkers
        && null report.unresolved && null failures
  in CleanupStatus complete (length report.pending) (length report.readWorkers)
       report.unresolved failures
