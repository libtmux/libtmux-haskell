-- | Synchronous detached creation with independently retained identity evidence.
-- The shared mutation runner owns deadline and operation correlation; this
-- layer preserves the journal when Timeout consumes an allocation exception.
module LibTmux.Internal.Creation
  ( performCreation, CreationRecovery, recoveryReceipt, observedReceipt
  , inspectRecovery, resumeRecovery, awaitRecovery, detachRecovery
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (STM)
import Control.DeepSeq (force)
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Data.ByteString (ByteString)
import Data.IORef
import Data.Maybe (listToMaybe)
import LibTmux.Creation (SessionOptions)
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope (TmuxException (..))
import LibTmux.Internal.SocketPin qualified as Pin
import System.Posix.Directory.ByteString qualified as Directory
import System.Posix.Env.ByteString qualified as Environment

-- | One failed creation's operation and its independently observed IDs.
-- The Runtime retains native/logical owners. Missing IDs do not prove absence.
data CreationRecovery = CreationRecovery !M.MutationRecovery !(Maybe R.CreationJournal)
instance Show CreationRecovery where
  showsPrec precedence (CreationRecovery recovery _) =
    showParen (precedence > 10) (showString "CreationRecovery " . shows recovery)
instance ExceptionAnnotation CreationRecovery

recoveryReceipt :: CreationRecovery -> R.ReadReceipt
recoveryReceipt (CreationRecovery recovery _) = M.recoveryReceipt recovery

observedReceipt :: CreationRecovery -> STM (Maybe G.CreatedSession)
observedReceipt recovery@(CreationRecovery _ journal) = do
  observed <- maybe (pure Nothing) R.journalReceipt journal
  let !generation = R.receiptGeneration (recoveryReceipt recovery)
  pure (createdValue generation <$> observed)

inspectRecovery :: CreationRecovery -> STM R.ReadRecovery
inspectRecovery (CreationRecovery recovery _) = M.inspectRecovery recovery

resumeRecovery :: CreationRecovery -> IO ()
resumeRecovery selected@(CreationRecovery recovery _) = recovering selected (M.resumeRecovery recovery)

awaitRecovery :: CreationRecovery -> IO R.ReadRecovery
awaitRecovery selected@(CreationRecovery recovery _) = recovering selected (M.awaitRecovery recovery)

detachRecovery :: CreationRecovery -> STM Bool
detachRecovery (CreationRecovery recovery _) = M.detachRecovery recovery

performCreation :: P.Hooks -> Int -> R.Runtime -> R.ServerHandle -> ByteString -> SessionOptions -> IO G.CreatedSession
performCreation hooks duration runtime server executable options = mask $ \restore -> do
  journal <- newIORef Nothing
  let retain failure@(ExceptionWithContext context (_ :: SomeException)) = do
        writeIORef journal (listToMaybe (Context.getExceptionAnnotations @R.CreationJournal context))
        rethrowIO failure
      submit remainingTime = do
        (cwd, environment) <- restore $ do
          cwd <- Directory.getWorkingDirectory
          environment <- Environment.getEnvironment
          pure (cwd, environment)
        left <- remainingTime
        let context = (N.spec executable []) {N.cwd = cwd, N.env = [key <> "=" <> value | (key, value) <- environment]}
        created <- catchNoPropagate
          (R.createSessionWith hooks left runtime server context options) retain
        let !observed = R.creationJournal created
        writeIORef journal (Just observed)
        pure (R.creationRequest created)
      decode = \case
        C.SessionCreated value -> evaluate (force (createdValue generation value))
        C.SessionCreatedWithErrors _ diagnostic -> throwIO (MutationAppliedWithErrors diagnostic)
        C.SessionCreationRejected diagnostic -> throwIO (MutationRejected diagnostic)
        C.SessionCreationUnknown _ problem -> throwIO (R.InvalidCommandReply problem)
      annotate failure@(ExceptionWithContext context (_ :: SomeException)) =
        case Context.getExceptionAnnotations @M.MutationRecovery context of
          [] -> rethrowIO failure
          recovery : _ -> do
            saved <- readIORef journal
            let selected = saved <|> listToMaybe (Context.getExceptionAnnotations @R.CreationJournal context)
            recovering (CreationRecovery recovery selected) (rethrowIO failure)
      generation = Pin.pinGeneration (R.serverPin server)
  catchNoPropagate (restore (M.performRequest duration runtime server submit decode)) annotate

createdValue :: G.Generation -> C.SessionReceipt -> G.CreatedSession
createdValue generation receipt = G.CreatedSession receipt.serverPid
  (G.SessionRef generation receipt.sessionId) (G.WindowRef generation receipt.windowId)
  (G.PaneRef generation receipt.paneId) receipt.windowIndex

recovering :: CreationRecovery -> IO a -> IO a
recovering recovery action = catchNoPropagate action $
  \(ExceptionWithContext context (problem :: SomeException)) ->
    rethrowIO (ExceptionWithContext (Context.addExceptionAnnotation recovery context) problem)
