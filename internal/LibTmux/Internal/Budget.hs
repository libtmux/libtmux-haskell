-- | Credits shared by private process pools in one explicit context.
--
-- Create a t'Budget' in 'IO' with a protected inspection byte allowance,
-- then reserve and release typed leases in STM using the operation's 'Class'.
-- Reservations survive cancelled waiters. A lease releases its credits at
-- most once, including after 'closeAdmission'. This is payload accounting,
-- not an RSS limit or a complete Runtime supervisor.
module LibTmux.Internal.Budget
  ( -- * Shared context
    Budget, Usage (..), Class (..), newBudget, inspectionAllowance, usage, closeAdmission
    -- * Reservations
  , ClientLease, ChildLease, ByteLease, acquireClient, acquireChild, acquireBytes
    -- * Retirement
  , releaseClient, releaseChild, releaseBytes
    -- * Admission failures
  , Resource (..), LimitError (..)
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception, throwIO)
import Control.Monad (unless, when)
import Data.Word (Word64)

data Budget = Budget !Word64 !(TVar State)

data State = State
  { observed :: !Usage
  , ordinaryChildren :: !Word64
  , ordinaryBytes :: !Word64
  }

data Usage = Usage
  { accepting :: !Bool
  , clients :: !Word64
  , children :: !Word64
  , pendingBytes :: !Word64
  }
  deriving stock (Eq, Show)

-- | Inspection can use protected capacity and borrow unused ordinary credits.
-- The class describes admission, not a command's effects or completion.
data Class = Ordinary | Inspection
  deriving stock (Eq, Show)

data Resource = Clients | Children | PendingBytes | OrdinaryChildren | OrdinaryPendingBytes
  deriving stock (Eq, Show)

-- | Rejected admission. Exhaustion records resource, requested amount,
-- current usage and limit. Failed reservations change no counters.
data LimitError
  = AdmissionClosed
  | Exhausted !Resource !Word64 !Word64 !Word64
  deriving stock (Eq, Show)
instance Exception LimitError

-- The context keeps counters, not a registry of released tokens.
data Lease = Lease !Budget !(TVar Bool) !Class !Word64 !Word64 !Word64
newtype ClientLease = ClientLease Lease
newtype ChildLease = ChildLease Lease
newtype ByteLease = ByteLease Lease

clientLimit, childLimit, byteLimit :: Word64
clientLimit = 8
childLimit = 16
byteLimit = 128 * 1024 * 1024

-- | Start a context with eight clients, sixteen children and 128 MiB of
-- pending payload reservations. Ordinary work leaves one child position and
-- the supplied byte allowance for inspection. Oversized allowances throw
-- 'LimitError'; zero protects only the child position.
newBudget :: Word64 -> IO Budget
newBudget protected = do
  when (protected > byteLimit) (throwIO (Exhausted PendingBytes protected 0 byteLimit))
  Budget protected <$> newTVarIO (State (Usage True 0 0 0) 0 0)

-- | The immutable byte allowance excluded from ordinary reservations.
inspectionAllowance :: Budget -> Word64
inspectionAllowance (Budget protected _) = protected

-- | Observe all counters in one transaction; no external resources are read.
usage :: Budget -> STM Usage
usage (Budget _ state) = (.observed) <$> readTVar state

-- | Reject future reservations without releasing existing leases or waiting
-- for cleanup. Owners must still call their corresponding release operation.
closeAdmission :: Budget -> STM ()
closeAdmission (Budget _ state) = modifyTVar' state $ \old ->
  old {observed = old.observed {accepting = False}}

-- | Reserve one client until its pin cleanup succeeds. Release with
-- 'releaseClient'; closed/exhausted contexts throw 'LimitError' in STM.
acquireClient :: Budget -> STM ClientLease
acquireClient budget = ClientLease <$> reserve budget Ordinary 1 0 0

-- | Reserve one child and its byte allowance atomically. Neither credit
-- changes on failure. Retain until physical retirement; see 'releaseChild'.
acquireChild :: Budget -> Class -> Word64 -> STM ChildLease
acquireChild budget allocation bytes = ChildLease <$> reserve budget allocation 0 1 bytes

-- | Reserve retained payload capacity independently of a child. An internal
-- consumer keeps this lease through decoding or charged ownership transfer.
-- Release with 'releaseBytes'. Zero bytes still require open admission.
acquireBytes :: Budget -> Class -> Word64 -> STM ByteLease
acquireBytes budget allocation bytes = ByteLease <$> reserve budget allocation 0 0 bytes

reserve :: Budget -> Class -> Word64 -> Word64 -> Word64 -> STM Lease
reserve budget@(Budget protected state) allocation clientDelta childDelta byteDelta = do
  current <- readTVar state
  let old = current.observed
      ordinary amount = if allocation == Ordinary then amount else 0
  unless old.accepting (throwSTM AdmissionClosed)
  checkLimit Clients clientDelta old.clients clientLimit
  checkLimit Children childDelta old.children childLimit
  when (allocation == Ordinary) $ do
    checkLimit OrdinaryChildren childDelta current.ordinaryChildren (childLimit - 1)
    checkLimit OrdinaryPendingBytes byteDelta current.ordinaryBytes (byteLimit - protected)
  checkLimit PendingBytes byteDelta old.pendingBytes byteLimit
  live <- newTVar True
  writeTVar state $! State
    { observed = old
      { clients = old.clients + clientDelta
      , children = old.children + childDelta
      , pendingBytes = old.pendingBytes + byteDelta
      }
    , ordinaryChildren = current.ordinaryChildren + ordinary childDelta
    , ordinaryBytes = current.ordinaryBytes + ordinary byteDelta
    }
  pure (Lease budget live allocation clientDelta childDelta byteDelta)

-- Compare before adding so an oversized Word64 cannot wrap around the cap.
checkLimit :: Resource -> Word64 -> Word64 -> Word64 -> STM ()
checkLimit resource requested used limit =
  when (requested > limit - used) (throwSTM (Exhausted resource requested used limit))

-- | Return a client credit once. Legal after 'closeAdmission'.
releaseClient :: ClientLease -> STM ()
releaseClient (ClientLease lease) = release lease

-- | Return the child and byte credits from 'acquireChild' once.
releaseChild :: ChildLease -> STM ()
releaseChild (ChildLease lease) = release lease

-- | Return the byte credits from 'acquireBytes' once.
releaseBytes :: ByteLease -> STM ()
releaseBytes (ByteLease lease) = release lease

release :: Lease -> STM ()
release (Lease (Budget _ state) live allocation clientDelta childDelta byteDelta) = do
  active <- readTVar live
  when active $ do
    current <- readTVar state
    let old = current.observed
        ordinary amount = if allocation == Ordinary then amount else 0
    writeTVar state $! State
      { observed = old
        { clients = old.clients - clientDelta
        , children = old.children - childDelta
        , pendingBytes = old.pendingBytes - byteDelta
        }
      , ordinaryChildren = current.ordinaryChildren - ordinary childDelta
      , ordinaryBytes = current.ordinaryBytes - ordinary byteDelta
      }
    writeTVar live False
