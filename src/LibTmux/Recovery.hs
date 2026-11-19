-- | Recover incomplete operations and scope cleanup using the exception
-- context returned by "LibTmux.Server" or by `tryWithContext`.
-- Inspection reads retained metadata. Resuming cleanup never submits
-- the original command again.
module LibTmux.Recovery
  ( -- * Scope cleanup
    CleanupRecovery, CleanupStatus (..), cleanupRecoveries, cleanupFailure, cleanupObservation
  , inspectCleanup, resumeCleanup, awaitCleanup, detachUnresolved
    -- * Capture
  , CaptureRecovery, captureRecoveries, recoveryOperation, recoveryGeneration
  , ReadRecovery (..), inspectCaptureRecovery, resumeCaptureRecovery, detachCaptureRecovery
    -- * Creation
  , CreationRecovery, creationRecoveries, creationOperation, creationGeneration
  , creationReceipt, inspectCreationRecovery, resumeCreationRecovery, awaitCreationRecovery, detachCreationRecovery
    -- * Mutation
  , MutationRecovery, mutationRecoveries, mutationOperation, mutationGeneration
  , inspectMutationRecovery, resumeMutationRecovery, awaitMutationRecovery, detachMutationRecovery
    -- * Program cleanup
  , ProgramRecovery, ProgramCleanupStatus (..), programRecoveries, programCleanupFailure
  , inspectProgramCleanup, resumeProgramCleanup
    -- * Control client cleanup
  , ControlRecovery, controlRecoveries, controlRetired, resumeControlCleanup
    -- * Operation metadata
  , Operation, Status (..), Stage (..), Outcome (..), operationStatus
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import LibTmux.Creation qualified as Creation
import LibTmux.Internal.Capture (CaptureRecovery)
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Control (ControlRecovery, controlRecoveries, controlRetired, resumeControlCleanup)
import LibTmux.Internal.Creation (CreationRecovery)
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Mutation (MutationRecovery)
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Runtime (ReadRecovery (..))
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler (Operation, Status (..), Stage (..), Outcome (..))
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.Scope
  ( CleanupRecovery, CleanupStatus (..), cleanupFailure, cleanupObservation
  , inspectCleanup, resumeCleanup, awaitCleanup, operational
  )
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Program
  ( ProgramRecovery, ProgramCleanupStatus (..), programRecoveries, programCleanupFailure
  , inspectProgramCleanup, resumeProgramCleanup
  )
import LibTmux.Snapshot (Generation)

-- | Correlated creation owners from 'LibTmux.Server.tryTmux' or 'tryWithContext'. Keep the
-- context when handling failure, including an applied command's hook error.
creationRecoveries :: ExceptionContext -> [CreationRecovery]
creationRecoveries = getExceptionAnnotations

-- | Metadata-only identity of the original creation operation.
creationOperation :: CreationRecovery -> Operation
creationOperation = R.receiptOperation . Create.recoveryReceipt

-- | Originating Server generation, including after the scope closes.
creationGeneration :: CreationRecovery -> Generation
creationGeneration = R.receiptGeneration . Create.recoveryReceipt

-- | Read any complete historical receipt already observed by the library.
-- This reads owned metadata without contacting tmux. 'Nothing' does not mean
-- no entity was created; unread or incomplete evidence cannot supply IDs.
creationReceipt :: CreationRecovery -> IO (Maybe Creation.CreatedEntities)
creationReceipt = atomically . Create.observedReceipt

-- | Inspect logical outcome and native ownership without external operations.
inspectCreationRecovery :: CreationRecovery -> IO ReadRecovery
inspectCreationRecovery = atomically . Create.inspectRecovery

-- | Resume existing cleanup; never execute the creation again.
resumeCreationRecovery :: CreationRecovery -> IO ()
resumeCreationRecovery = operational . Create.resumeRecovery

-- | Join the original native child and decoder. Logical uncertainty can
-- remain, and this wait proves no hook/background-job completion.
awaitCreationRecovery :: CreationRecovery -> IO ReadRecovery
awaitCreationRecovery = operational . Create.awaitRecovery

-- | Relinquish logical uncertainty while preserving physical cleanup owners.
-- This does not remove the created session or repeat the command.
detachCreationRecovery :: CreationRecovery -> IO Bool
detachCreationRecovery = operational . atomically . Create.detachRecovery

-- | Cleanup owners retained by a failed or cancelled scope. The context
-- comes from 'LibTmux.Server.tryTmux' or 'tryWithContext'. Inspection performs no tmux IO.
-- Nested scopes can contribute overlapping owners; inspect and resume each
-- retained responsibility through 'inspectCleanup' and 'resumeCleanup'.
cleanupRecoveries :: ExceptionContext -> [CleanupRecovery]
cleanupRecoveries = getExceptionAnnotations

-- | Relinquish one logical operation from this cleanup scope. This releases
-- no native resources and does not prove that daemon-side work completed.
detachUnresolved :: CleanupRecovery -> Operation -> IO Bool
detachUnresolved recovery = operational . Scope.detachUnresolved recovery

-- | Read owners retained by a capture or Server version check, including cancellation.
captureRecoveries :: ExceptionContext -> [CaptureRecovery]
captureRecoveries = getExceptionAnnotations

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

-- | Recover the exact operation after failure, timeout or cancellation. The
-- context comes from 'LibTmux.Server.tryTmux' or 'tryWithContext'; cancellation keeps its
-- original exception class and is not caught by 'LibTmux.Server.tryTmux'.
mutationRecoveries :: ExceptionContext -> [MutationRecovery]
mutationRecoveries = getExceptionAnnotations

-- | Metadata-only identity of the original command. 'operationStatus' remains
-- available after native cleanup; this value contains no command operands.
mutationOperation :: MutationRecovery -> Operation
mutationOperation = R.receiptOperation . M.recoveryReceipt

-- | Server generation associated with this mutation's recovery owner.
mutationGeneration :: MutationRecovery -> Generation
mutationGeneration = R.receiptGeneration . M.recoveryReceipt

-- | Inspect the original operation's logical and physical ownership locally.
-- This performs no tmux command. An unknown outcome does not become success
-- merely because the native child has exited.
inspectMutationRecovery :: MutationRecovery -> IO ReadRecovery
inspectMutationRecovery = atomically . M.inspectRecovery

-- | Resume existing native cleanup and decoder ownership, without repeating
-- the command. Allocation failure retains the same recovery owner.
resumeMutationRecovery :: MutationRecovery -> IO ()
resumeMutationRecovery = operational . M.resumeRecovery

-- | Wait for the original decoder and native child to retire. This may still
-- return retained 'OutcomeUnknown'; it does not wait for a daemon hook job.
-- Cancellation keeps this recovery owner in the new exception context.
awaitMutationRecovery :: MutationRecovery -> IO ReadRecovery
awaitMutationRecovery = operational . M.awaitRecovery

-- | Relinquish this operation's logical uncertainty. This neither cancels
-- daemon work nor releases native resources, and never repeats the mutation.
detachMutationRecovery :: MutationRecovery -> IO Bool
detachMutationRecovery = operational . atomically . M.detachRecovery

-- | Read retained operation metadata, including after its physical cleanup.
operationStatus :: Operation -> IO Status
operationStatus = atomically . S.status
