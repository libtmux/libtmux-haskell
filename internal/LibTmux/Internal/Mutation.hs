-- | One synchronous mutation and its retained ownership. A deadline bounds
-- submission as well as waiting; recovery never dispatches the command again.
module LibTmux.Internal.Mutation
  ( performMutation, performRequest, MutationRecovery, recoveryReceipt, inspectRecovery
  , resumeRecovery, awaitRecovery, detachRecovery
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (STM, atomically, check)
import Control.Exception
  ( ExceptionWithContext (..), SomeException, catchNoPropagate, fromException
  , mask, onException, rethrowIO, throwIO, toException
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (listToMaybe)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope (TmuxException (..))
import System.Timeout (timeout)

-- | Reachable ownership for one failed or cancelled mutation. The receipt
-- retains metadata only; the Runtime retains outstanding native and logical
-- owners. Recovery never repeats the command. See "LibTmux.Server".
data MutationRecovery = MutationRecovery !R.Runtime !R.ServerHandle !R.ReadReceipt
instance Show MutationRecovery where
  showsPrec precedence (MutationRecovery _ _ receipt) =
    showParen (precedence > 10) (showString "MutationRecovery " . shows receipt)
instance ExceptionAnnotation MutationRecovery

recoveryReceipt :: MutationRecovery -> R.ReadReceipt
recoveryReceipt (MutationRecovery _ _ receipt) = receipt

inspectRecovery :: MutationRecovery -> STM R.ReadRecovery
inspectRecovery (MutationRecovery runtime server receipt) = R.inspectReceipt runtime server receipt

resumeRecovery :: MutationRecovery -> IO ()
resumeRecovery recovery@(MutationRecovery runtime server receipt) =
  recovering recovery (R.resumeReceipt runtime server receipt)

awaitRecovery :: MutationRecovery -> IO R.ReadRecovery
awaitRecovery recovery = recovering recovery $ atomically $ do
  observed <- inspectRecovery recovery
  check (not observed.workerOwned && not observed.nativeOwned)
  pure observed

detachRecovery :: MutationRecovery -> STM Bool
detachRecovery (MutationRecovery runtime server receipt) = R.detachReceipt runtime server receipt

performMutation :: P.Hooks -> Int -> R.Runtime -> R.ServerHandle -> ByteString -> C.Mutation -> IO ()
performMutation hooks duration runtime server executable mutation =
  performRequest duration runtime server
    (\remainingTime -> remainingTime >>= \left -> R.mutateWith hooks left runtime server executable mutation) $ \case
      C.Applied -> pure ()
      C.Rejected diagnostic -> throwIO (MutationRejected diagnostic)
      C.AppliedWithErrors diagnostic -> throwIO (MutationAppliedWithErrors diagnostic)

-- | Share one absolute deadline and correlated owner across typed mutations.
-- Submission obtains remaining time after its own context acquisition; the
-- decoder runs within the same deadline. Recovery never resubmits the action.
performRequest
  :: Int -> R.Runtime -> R.ServerHandle
  -> (IO Int -> IO (R.Request value)) -> (value -> IO result) -> IO result
performRequest duration runtime server submit decode = mask $ \restore -> do
  when (duration < 1 || duration > 10000000)
    (throwIO (InvalidConfiguration "mutation timeout must be positive and at most ten seconds"))
  receipt <- newIORef Nothing
  let annotate (ExceptionWithContext context (problem :: SomeException)) = do
        current <- readIORef receipt
        let selected = current <|> listToMaybe (Context.getExceptionAnnotations @R.ReadReceipt context)
        case selected of
          Nothing -> rethrowIO (ExceptionWithContext context problem)
          Just value -> recovering (MutationRecovery runtime server value)
            (rethrowIO (ExceptionWithContext context problem))
      owned deadline = mask $ \unmask -> do
        request <- catchNoPropagate (submit (remaining deadline)) $
          \failure@(ExceptionWithContext context (problem :: SomeException)) -> do
            -- Timeout consumes its exception; retain correlation before conversion.
            writeIORef receipt (listToMaybe (Context.getExceptionAnnotations @R.ReadReceipt context))
            case fromException @R.ReadError problem of
              Just (R.InvalidCommandOperands invalid) -> rethrowIO
                (ExceptionWithContext context (toException (InvalidMutationArgument (argumentError invalid))))
              _ -> rethrowIO failure
        let !current = R.readReceipt request
        writeIORef receipt (Just current)
        response <- unmask (R.awaitRead request) `onException` R.cancelRead runtime request
        case response of
          R.ReadValue value -> decode value
          R.ReadUnavailable _ (Just problem)
            | Just R.ReadExpired <- fromException problem -> throwIO MutationTimedOut
            | otherwise -> throwIO problem
          R.ReadUnavailable _ Nothing -> throwIO (OperationFailed (toException R.ReadCancelled))
      timed = do
        started <- getMonotonicTimeNSec
        let delta = fromIntegral duration * 1000
        when (started > maxBound - delta) (throwIO R.ReadClockOverflow)
        let deadline = started + delta
        completed <- timeout duration (owned deadline)
        case completed of
          Nothing -> throwIO MutationTimedOut
          Just value -> remaining deadline >> pure value
  catchNoPropagate (restore timed) annotate
  where
    argumentError (C.NulOperand field) = field <> " contains NUL"
    argumentError (C.EncodedCommandTooLarge field) = field <> " exceeds the command size limit"
    argumentError (C.InvalidOperand field reason) = field <> ": " <> reason

remaining :: Word64 -> IO Int
remaining deadline = do
  now <- getMonotonicTimeNSec
  when (now >= deadline) (throwIO MutationTimedOut)
  pure (fromIntegral ((deadline - now + 999) `div` 1000))

recovering :: MutationRecovery -> IO a -> IO a
recovering recovery action = catchNoPropagate action $
  \(ExceptionWithContext context (problem :: SomeException)) ->
    rethrowIO (ExceptionWithContext (Context.addExceptionAnnotation recovery context) problem)
