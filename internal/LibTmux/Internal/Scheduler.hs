-- | Bounded logical admission, separate from physical process ownership.
--
-- Create a t'Scheduler' with 'newScheduler', 'admit' an operation, then
-- dispatch with 'claim'. 'status' separates observed progress, the first
-- caller outcome and retained responsibility. Cancellation of 'await' does
-- not release admission. 'connectionRetired' also retains uncertain work.
--
-- This component performs no tmux IO and proves no external completion.
-- The Runtime must supply evidence to 'finish' or 'refuseBeforeBirth', and
-- protect physical-child and byte capacity for inspection too. The logical
-- reserve here does not reserve those resources.
module LibTmux.Internal.Scheduler
  ( -- * Context and admission
    Scheduler, Operation, Lane (..), newScheduler, admit, claim
    -- * Ownership groups
  , Group, newGroup, admitIn, outstandingIn, memberOf
    -- * Detached observations
  , Stage (..), Outcome (..), Status (..), status, await, outstanding
    -- * Evidence and uncertainty
  , Completion (..), markDispatched, markResponseClosed, finish, markUnknown
  , cancelQueued, refuseBeforeBirth, connectionRetired, detachResponsibility
    -- * Shutdown and errors
  , closeAdmission, AdmissionError (..)
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception)
import Control.Monad (filterM, unless, when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)

-- | One bounded context. Detached t'Operation' handles do not retain it.
data Scheduler = Scheduler !Unique !(TVar State)
data State = State
  { accepting :: !Bool
  , nextKey :: !(Maybe Word64)
  , operations :: !(Map Word64 Operation)
  }

-- | Metadata-only operation identity, readable after responsibility retires.
-- Its owning scope controls advancement and explicit detachment.
data Operation = Operation !Unique !Word64 !Lane !(TVar Status) !(Maybe Group)
  deriving stock (Eq)

instance Show Operation where
  showsPrec precedence (Operation _ key _ _ _) =
    showParen (precedence > 10) (showString "Operation " . shows key)

-- | Opaque metadata identifying one owner's operations. This retains no
-- Runtime, endpoint, resource or scheduler. Groups share admission limits.
newtype Group = Group Unique
  deriving stock (Eq)

-- | Allocate a fresh group without reserving admission or resources.
newGroup :: IO Group
newGroup = Group <$> newUnique

-- | Internal classification. Unknown raw commands belong to 'Waiting'.
-- Mutations serialize until proof or explicit 'detachResponsibility'.
data Lane = Inspection | ScalarRead | Mutation | Waiting
  deriving stock (Eq, Show)

-- | Last observed progress. Publishing an uncertain 'Outcome' does not
-- advance this stage or establish 'OperationComplete'.
data Stage = Queued | Dispatching | Dispatched | ResponseClosed | OperationComplete
  deriving stock (Eq, Show)

-- | First caller result. Later evidence can retire responsibility without
-- rewriting 'OutcomeUnknown' or 'ConnectionRetired'.
data Outcome
  = Succeeded -- ^ Validated successful response and completion proof.
  | Failed -- ^ Validated command failure.
  | NotDispatched -- ^ Proof that the operation was never dispatched.
  | OutcomeUnknown -- ^ Dispatch may have happened; completion remains uncertain.
  | ConnectionRetired -- ^ The connection retired while responsibility remained.
  deriving stock (Eq, Show)

-- | Progress, published result and responsibility are independent observations.
-- A retained uncertain operation still consumes admission and its lane permit.
data Status = Status
  { stage :: !Stage -- ^ Last proven progress.
  , outcome :: !(Maybe Outcome) -- ^ First published caller result, when available.
  , retained :: !Bool -- ^ Whether the scope still retains logical responsibility.
  }
  deriving stock (Eq, Show)

-- | Operational completion evidence supplied by the Runtime after
-- 'markResponseClosed'. This constructor does not obtain the evidence.
data Completion = Success | CommandFailure
  deriving stock (Eq, Show)

-- | Rejected admission or transition. 'InvalidTransition' records the
-- required preceding stage followed by the actual stage. No state changes
-- survive a rejected STM action.
data AdmissionError
  = AdmissionClosed
  | AdmissionFull
  | OrdinaryFull
  | KeyExhausted
  | ForeignContext
  | InvalidTransition !Stage !Stage
  deriving stock (Eq, Show)
instance Exception AdmissionError

-- | Create an independent context with 64 admission slots. Ordinary work
-- may occupy 63; inspection can use the remaining capacity. Dispatch allows
-- four waiting jobs, one mutation and four reads, reserving a read permit
-- for inspection. These are selected bounds, not throughput measurements.
newScheduler :: IO Scheduler
newScheduler = Scheduler <$> newUnique <*> newTVarIO (State True (Just 0) Map.empty)

-- | Reserve logical responsibility before dispatch. Saturation or closure
-- throws 'AdmissionError' immediately. Retire queued work with 'cancelQueued';
-- active work requires evidence or explicit 'detachResponsibility'.
admit :: Scheduler -> Lane -> STM Operation
admit scheduler = reserve scheduler Nothing

-- | Reserve an operation in one group, under the scheduler's global limits.
-- Group membership survives logical retirement for physical-owner selection.
-- The token is forced before admission so metadata retains no caller thunk.
admitIn :: Scheduler -> Group -> Lane -> STM Operation
admitIn scheduler group = reserve scheduler (Just group)

reserve :: Scheduler -> Maybe Group -> Lane -> STM Operation
reserve (Scheduler context variable) group lane = do
  case group of
    Just token -> token `seq` pure ()
    Nothing -> pure ()
  current <- readTVar variable
  unless current.accepting (throwSTM AdmissionClosed)
  when (Map.size current.operations >= 64) (throwSTM AdmissionFull)
  let ordinary = Map.size (Map.filter (\(Operation _ _ ownedLane _ _) -> ownedLane /= Inspection) current.operations)
  when (lane /= Inspection && ordinary >= 63) (throwSTM OrdinaryFull)
  key <- maybe (throwSTM KeyExhausted) pure current.nextKey
  observed <- newTVar (Status Queued Nothing True)
  let operation = Operation context key lane observed group
      following = if key == maxBound then Nothing else Just (key + 1)
  writeTVar variable $! current {nextKey = following, operations = Map.insert key operation current.operations}
  pure operation

-- | Read detached metadata without IO, including after 'closeAdmission' or
-- explicit 'detachResponsibility'. This does not inspect tmux.
status :: Operation -> STM Status
status (Operation _ _ _ observed _) = readTVar observed

-- | Observe retained metadata in admission order, including uncertain work.
-- The opaque handles remain bound to this context for explicit detach.
outstanding :: Scheduler -> STM [(Operation, Status)]
outstanding (Scheduler _ variable) = do
  current <- readTVar variable
  mapM (\operation -> (operation,) <$> status operation) (Map.elems current.operations)

-- | Retained logical operations in one group, in admission order. Detached
-- operations remain group members but no longer appear in this list.
outstandingIn :: Scheduler -> Group -> STM [(Operation, Status)]
outstandingIn scheduler group = filter (memberOf group . fst) <$> outstanding scheduler

-- | Match ownership metadata, including after completion or detachment.
-- This does not establish logical or physical liveness.
memberOf :: Group -> Operation -> Bool
memberOf group (Operation _ _ _ _ origin) = origin == Just group

-- | Wait for the first published 'Outcome'. Cancelling this transaction
-- changes neither admission nor responsibility; see 'markUnknown'.
await :: Operation -> STM Outcome
await operation = status operation >>= maybe retry pure . (.outcome)

-- | Claim the oldest eligible queued operation and its lane permit together.
-- Saturated classes do not obstruct eligible inspection. Retry while open
-- without eligible work; return 'Nothing' only after 'closeAdmission'.
claim :: Scheduler -> STM (Maybe Operation)
claim (Scheduler _ variable) = do
  current <- readTVar variable
  if not current.accepting then pure Nothing else do
    entries <- mapM (\operation -> do observed <- status operation; pure (operation, observed)) (Map.elems current.operations)
    let active = [lane | (Operation _ _ lane _ _, observed) <- entries, observed.stage /= Queued]
        count lane = length (filter (== lane) active)
        readCount = count ScalarRead + count Inspection
        eligible lane = length active < 16 && case lane of
          Inspection -> readCount < 4
          ScalarRead -> count ScalarRead < 3 && readCount < 4
          Mutation -> count Mutation < 1
          Waiting -> count Waiting < 4
    choose eligible entries
  where
    choose _ [] = retry
    choose eligible ((operation@(Operation _ _ lane observed _), current) : rest) =
      if current.stage == Queued && eligible lane then do
        writeTVar observed $! current {stage = Dispatching}
        pure (Just operation)
      else choose eligible rest

-- | Record dispatch evidence after 'claim'. Repeating the same transition
-- is harmless; a retired handle stays retired. This supplies no IO evidence.
markDispatched :: Scheduler -> Operation -> STM ()
markDispatched = advance Dispatching Dispatched

-- | Record a closed response after 'markDispatched'. This is distinct from
-- operation completion: only 'finish' can record that stronger evidence.
markResponseClosed :: Scheduler -> Operation -> STM ()
markResponseClosed = advance Dispatched ResponseClosed

-- | Record operation-specific completion after 'markResponseClosed' and
-- release logical responsibility once. Preserve any earlier caller outcome.
-- Physical children and buffers still need their independent cleanup.
finish :: Scheduler -> Operation -> Completion -> STM Bool
finish scheduler operation completion = withLive scheduler operation False $ \current -> do
  requireStage ResponseClosed current
  retire scheduler operation ((publish result current) {stage = OperationComplete})
  where result = case completion of Success -> Succeeded; CommandFailure -> Failed

-- | Publish uncertainty for active work, retaining admission and its permit.
-- Return 'False' if already published or retired. This does not cancel work.
markUnknown :: Scheduler -> Operation -> STM Bool
markUnknown = publishActive OutcomeUnknown

-- | Cancel only queued work, publishing 'NotDispatched' and retiring its
-- admission. Active or previously retired operations return 'False'.
cancelQueued :: Scheduler -> Operation -> STM Bool
cancelQueued scheduler operation = withLive scheduler operation False $ \current ->
  if current.stage == Queued then retire scheduler operation (publish NotDispatched current)
  else pure False

-- | Retire a claimed operation only with proven pre-birth refusal. Preserve
-- earlier uncertainty rather than rewriting its published outcome. This
-- function requires 'Dispatching'; it does not establish non-dispatch itself.
refuseBeforeBirth :: Scheduler -> Operation -> STM Bool
refuseBeforeBirth scheduler operation = withLive scheduler operation False $ \current -> do
  requireStage Dispatching current
  retire scheduler operation (publish NotDispatched current)

-- | Publish connection retirement for active work without releasing debt.
-- A retired endpoint does not prove a server job stopped. Later 'finish',
-- 'refuseBeforeBirth' or explicit 'detachResponsibility' can retire it.
connectionRetired :: Scheduler -> Operation -> STM Bool
connectionRetired = publishActive ConnectionRetired

-- | Explicitly relinquish uncertain logical responsibility. Accept only
-- 'OutcomeUnknown' or 'ConnectionRetired'; otherwise return 'False'. Keep
-- the last stage/outcome, and close no native resource. Detaching a mutation
-- permits the next mutation despite possible continuing external effects.
detachResponsibility :: Scheduler -> Operation -> STM Bool
detachResponsibility scheduler operation = withLive scheduler operation False $ \current ->
  if current.outcome `elem` [Just OutcomeUnknown, Just ConnectionRetired]
    then retire scheduler operation current
    else pure False

-- | Close admission, settle queued work as 'NotDispatched' and return all
-- retained active handles for supervision. Wake blocked 'claim' transactions.
-- Repeated close preserves active debt; it does not release native resources.
closeAdmission :: Scheduler -> STM [Operation]
closeAdmission scheduler@(Scheduler _ variable) = do
  current <- readTVar variable
  writeTVar variable $! current {accepting = False}
  filterM (\operation -> do
    observed <- status operation
    if observed.stage == Queued then cancelQueued scheduler operation >> pure False
    else pure True) (Map.elems current.operations)

withLive :: Scheduler -> Operation -> a -> (Status -> STM a) -> STM a
withLive (Scheduler context variable) (Operation origin key _ observed _) absent action = do
  unless (context == origin) (throwSTM ForeignContext)
  current <- readTVar variable
  if Map.member key current.operations then readTVar observed >>= action
  else pure absent

advance :: Stage -> Stage -> Scheduler -> Operation -> STM ()
advance required target scheduler operation@(Operation _ _ _ observed _) =
  withLive scheduler operation () $ \current ->
    unless (current.stage == target) $ do
      requireStage required current
      writeTVar observed $! current {stage = target}

requireStage :: Stage -> Status -> STM ()
requireStage required current =
  unless (current.stage == required) (throwSTM (InvalidTransition required current.stage))

publish :: Outcome -> Status -> Status
publish result current = case current.outcome of
  -- Force the enum too, so detached metadata cannot retain a caller thunk.
  Nothing -> result `seq` current {outcome = Just result}
  Just _ -> current

publishActive :: Outcome -> Scheduler -> Operation -> STM Bool
publishActive result scheduler operation@(Operation _ _ _ observed _) =
  withLive scheduler operation False $ \current -> do
    when (current.stage == Queued) (throwSTM (InvalidTransition Dispatching Queued))
    case current.outcome of
      Just _ -> pure False
      Nothing -> do
        writeTVar observed $! publish result current
        pure True

retire :: Scheduler -> Operation -> Status -> STM Bool
retire (Scheduler _ variable) (Operation _ key _ observed _) current = do
  context <- readTVar variable
  writeTVar observed $! current {retained = False}
  writeTVar variable $! context {operations = Map.delete key context.operations}
  pure True
