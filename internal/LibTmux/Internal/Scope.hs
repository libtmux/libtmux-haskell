-- | Exception and recovery policy for an owned Runtime scope.
module LibTmux.Internal.Scope
  ( TmuxException (..), CleanupStatus (..), CleanupRecovery
  , CleanupActions (..), customCleanupRecovery, observed
  , runScope, runServerScope, cleanupRecoveries, cleanupFailure, cleanupObservation, inspectCleanup, resumeCleanup
  , awaitCleanup, detachUnresolved
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Data.ByteString (ByteString)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Version qualified as Version

-- | Library operational failures. Context-preserving catching retains any
-- cleanup owners; the original application or cancellation exception keeps
-- its class when the callback itself failed.
data TmuxException
  = ServerClosed -- ^ Admission through the retained Server handle has closed.
  | RuntimeClosed -- ^ Admission through the retained Runtime has closed.
  | InvalidConfiguration !Text -- ^ Configuration failed before acquisition.
  | InvalidObservation !Text -- ^ Acquired metadata failed final validation.
  | InvalidTarget !Text -- ^ Target belongs to a different connection or an offline fixture.
  | UnsupportedTmuxVersion !Version.VersionError -- ^ Daemon release is older than the supported minimum.
  | InvalidMutationArgument !Text -- ^ Invalid command operand; no command was admitted.
  | MutationRejected !ByteString -- ^ tmux rejected the primary command; bounded diagnostic bytes.
  | MutationAppliedWithErrors !ByteString -- ^ The primary command ran, then a command hook failed.
  | MutationTimedOut -- ^ The deadline elapsed; a correlated recovery may retain an unknown outcome.
  | OperationFailed !SomeException -- ^ Known backend failure with its original cause.
  | CleanupFailed !CleanupStatus !(Maybe SomeException) -- ^ Cleanup remained incomplete or its worker could not start.
  deriving stock (Show)
instance Exception TmuxException

-- | Local observations of the selected physical and logical responsibility.
-- Each inspection returns new metadata; it performs no tmux operation.
data CleanupStatus = CleanupStatus
  { complete :: !Bool -- ^ All physical owners, operation workers and logical responsibility have retired.
  , pendingHandles :: !Int -- ^ Server handles still awaiting physical retirement.
  , pendingReads :: !Int -- ^ Decoder or recovery workers retaining operation envelopes.
  , unresolved :: ![(S.Operation, S.Status)] -- ^ Retained logical operations with their observed status.
  , failures :: ![SomeException] -- ^ Currently observed pin, worker or cleanup-request failures.
  }
  deriving stock (Show)

-- | A physical owner outside the Runtime, with the same public recovery policy.
data CleanupActions = CleanupActions
  { observeCleanup :: !(IO CleanupStatus)
  , requestCleanup :: !(IO CleanupStatus)
  , waitCleanup :: !(IO CleanupStatus)
  , detachCleanup :: !(S.Operation -> IO Bool)
  }

data Target
  = RuntimeTarget !R.Runtime
  | ServerTarget !R.Runtime !R.ServerOwner
  | CustomTarget !CleanupActions

-- | Reachable responsibility after an incomplete or failed scope release.
-- Retaining this value keeps its selected cleanup target and Runtime reachable.
data CleanupRecovery = CleanupRecovery !Target !CleanupStatus !(Maybe SomeException)
instance Show CleanupRecovery where
  show _ = "CleanupRecovery"
instance ExceptionAnnotation CleanupRecovery

customCleanupRecovery :: CleanupActions -> CleanupStatus -> Maybe SomeException -> CleanupRecovery
customCleanupRecovery actions = CleanupRecovery (CustomTarget actions)

-- | Protect one registered owner, including its pin acquisition. Keep the
-- registration handoff masked and restore the action with the outer restore.
runServerScope :: R.Runtime -> R.ServerOwner -> IO a -> IO a
runServerScope runtime owner = runTarget (ServerTarget runtime owner)

runScope :: R.Runtime -> IO a -> IO a
runScope runtime = runTarget (RuntimeTarget runtime)

runTarget :: Target -> IO a -> IO a
runTarget target action = mask $ \restore -> do
  case target of
    RuntimeTarget _ -> pure ()
    CustomTarget _ -> pure ()
    ServerTarget runtime owner -> do
      _ <- atomically (R.inspectServerOwner runtime owner)
      pure ()
  body <- tryWithContext @SomeException (restore action)
  cleanup <- tryWithContext @SomeException (shutdownTarget target)
  case cleanup of
    Right status -> do
      if status.complete then either rethrowIO pure body else do
        let !recovery = CleanupRecovery target status Nothing
        case body of
          Left primary -> rethrowIO (annotated recovery primary)
          Right _ -> rethrowIO (annotated recovery
            (ExceptionWithContext mempty (toException (CleanupFailed status Nothing))))
    Left problem -> do
      status <- inspectTarget target
      let ExceptionWithContext _ cause = problem
          !recovery = CleanupRecovery target status (Just cause)
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
inspectCleanup (CleanupRecovery target _ _) = inspectTarget target

-- | Retry bounded owned cleanup. An incomplete result retains this owner;
-- the operation does not retry a tmux command or release logical uncertainty.
resumeCleanup :: CleanupRecovery -> IO CleanupStatus
resumeCleanup recovery@(CleanupRecovery target _ _) =
  recoverCleanup recovery (shutdownTarget target)

-- | Wait for this target's physical cleanup, then inspect its logical debt.
-- The wait has no deadline.
-- Cancellation or failure preserves an annotated cleanup owner. Use
-- 'resumeCleanup' when the caller requires a bounded attempt.
awaitCleanup :: CleanupRecovery -> IO CleanupStatus
awaitCleanup recovery@(CleanupRecovery target _ _) = recoverCleanup recovery (awaitTarget target)

detachUnresolved :: CleanupRecovery -> S.Operation -> IO Bool
detachUnresolved (CleanupRecovery target _ _) operation = case target of
  RuntimeTarget runtime -> atomically (R.detachOperation runtime operation)
  ServerTarget runtime owner -> atomically (R.detachServerOwnerOperation runtime owner operation)
  CustomTarget actions -> actions.detachCleanup operation

annotated :: CleanupRecovery -> ExceptionWithContext SomeException -> ExceptionWithContext SomeException
annotated recovery (ExceptionWithContext context problem) =
  ExceptionWithContext (Context.addExceptionAnnotation recovery context) problem

throwCleanup :: CleanupRecovery -> ExceptionWithContext SomeException -> IO a
throwCleanup recovery problem@(ExceptionWithContext context cause) =
  case fromException @SomeAsyncException cause of
    Just _ -> rethrowIO (annotated recovery problem)
    Nothing -> rethrowIO (annotated recovery (ExceptionWithContext context
      (toException (CleanupFailed (cleanupObservation recovery) (Just cause)))))

recoverCleanup :: CleanupRecovery -> IO CleanupStatus -> IO CleanupStatus
recoverCleanup (CleanupRecovery target _ _) action =
  catchNoPropagate action $ \problem@(ExceptionWithContext _ (cause :: SomeException)) -> do
    status <- inspectTarget target
    let !recovery = CleanupRecovery target status (Just cause)
    throwCleanup recovery problem

inspectTarget :: Target -> IO CleanupStatus
inspectTarget (RuntimeTarget runtime) = observed <$> atomically (R.inspect runtime)
inspectTarget (ServerTarget runtime owner) = observed <$> atomically (R.inspectServerOwner runtime owner)
inspectTarget (CustomTarget actions) = actions.observeCleanup

shutdownTarget :: Target -> IO CleanupStatus
shutdownTarget (RuntimeTarget runtime) = observed <$> R.shutdown runtime
shutdownTarget (ServerTarget runtime owner) = observed <$> R.shutdownServerOwner runtime owner
shutdownTarget (CustomTarget actions) = actions.requestCleanup

awaitTarget :: Target -> IO CleanupStatus
awaitTarget target@(RuntimeTarget runtime) = R.awaitCleanup runtime >> inspectTarget target
awaitTarget target@(ServerTarget runtime owner) = R.awaitServerOwnerCleanup runtime owner >> inspectTarget target
awaitTarget (CustomTarget actions) = actions.waitCleanup

observed :: R.Report -> CleanupStatus
observed report =
  let failures = map snd report.closeFailures
        <> [problem | (_, P.PinCleanupFailed problem) <- report.pending]
        <> catMaybes (map snd report.readWorkers)
      complete = null report.pending && null report.readWorkers
        && null report.unresolved && null failures
  in CleanupStatus complete (length report.pending) (length report.readWorkers)
       report.unresolved failures
