-- | Execute guarded relocation through the ordinary owned mutation lane.
module LibTmux.Internal.Relocation
  ( Placement (..), performRelocation, RelocationRecovery, observedReceipt
  , inspectRecovery, resumeRecovery, awaitRecovery, detachRecovery
  ) where

import Control.Concurrent.STM (STM)
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Data.ByteString (ByteString)
import LibTmux.Creation (PaneRelocationReceipt (..), WindowSlot (..))
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope (TmuxException (..))

data Placement
  = MoveTo !G.PaneRef !WindowSlot !G.WindowRef
  | BreakTo !G.PaneRef !WindowSlot

-- | Keep the original mutation owner and its bounded native evidence.
data RelocationRecovery = RelocationRecovery !M.MutationRecovery !R.RelocationJournal !Placement

instance Show RelocationRecovery where
  showsPrec precedence (RelocationRecovery recovery _ _) =
    showParen (precedence > 10) (showString "RelocationRecovery " . shows recovery)

instance ExceptionAnnotation RelocationRecovery

observedReceipt :: RelocationRecovery -> STM (Maybe PaneRelocationReceipt)
observedReceipt (RelocationRecovery _ journal placement) = do
  evidence <- R.journalRelocation journal
  pure (evidence >>= placedReceipt placement)

inspectRecovery :: RelocationRecovery -> STM R.ReadRecovery
inspectRecovery (RelocationRecovery recovery _ _) = M.inspectRecovery recovery

resumeRecovery :: RelocationRecovery -> IO ()
resumeRecovery selected@(RelocationRecovery recovery _ _) =
  recovering selected (M.resumeRecovery recovery)

awaitRecovery :: RelocationRecovery -> IO R.ReadRecovery
awaitRecovery selected@(RelocationRecovery recovery _ _) =
  recovering selected (M.awaitRecovery recovery)

detachRecovery :: RelocationRecovery -> STM Bool
detachRecovery (RelocationRecovery recovery _ _) = M.detachRecovery recovery

performRelocation :: Int -> R.Runtime -> R.ServerHandle -> ByteString -> C.PaneRelocation
  -> Placement -> IO PaneRelocationReceipt
performRelocation duration runtime server executable command placement = do
  journal <- R.newRelocationJournal (C.relocationWire command)
  let submit remaining = do
        left <- remaining
        R.relocateWith P.defaultHooks left runtime server executable command journal
      decode = \case
        C.RelocationCompleted evidence ->
          maybe (throwIO (R.InvalidCommandReply C.UnexpectedReply)) pure (placedReceipt placement evidence)
        C.RelocationCompletedWithErrors _ diagnostic -> throwIO (MutationAppliedWithErrors diagnostic)
        C.RelocationRejected diagnostic -> throwIO (MutationRejected diagnostic)
        C.RelocationRefused -> throwIO (MutationRejected "pane relocation context changed or destination is occupied")
      annotate original@(ExceptionWithContext context (_ :: SomeException)) =
        case Context.getExceptionAnnotations @M.MutationRecovery context of
          recovery : _ -> recovering (RelocationRecovery recovery journal placement) (rethrowIO original)
          [] -> rethrowIO original
  catchNoPropagate (M.performRequest duration runtime server submit decode) annotate

placedReceipt :: Placement -> C.RelocationEvidence -> Maybe PaneRelocationReceipt
placedReceipt (MoveTo pane slot window) (C.RelocationAccepted Nothing) =
  Just (MoveAccepted pane slot window)
placedReceipt (BreakTo pane slot) (C.RelocationAccepted receipt) =
  BreakAccepted pane slot <$> traverse (reportedLink pane slot) receipt
placedReceipt (BreakTo pane slot) (C.RelocationPrinted receipt) =
  BreakReported pane slot <$> reportedLink pane slot receipt
placedReceipt _ _ = Nothing

reportedLink :: G.PaneRef -> WindowSlot -> C.SessionReceipt -> Maybe (WindowSlot, G.WindowRef)
reportedLink (G.PaneRef generation pane) (WindowSlot session@(G.SessionRef _ ident) _) receipt
  | receipt.paneId == pane && receipt.sessionId == ident =
      Just (WindowSlot session receipt.windowIndex, G.WindowRef generation receipt.windowId)
  | otherwise = Nothing

recovering :: RelocationRecovery -> IO a -> IO a
recovering recovery action = catchNoPropagate action $
  \(ExceptionWithContext context (problem :: SomeException)) ->
    rethrowIO (ExceptionWithContext (Context.addExceptionAnnotation recovery context) problem)
