-- | Credits shared by private process pools in one explicit context.
--
-- Create a 'Budget' in 'IO', then reserve and release typed leases in STM.
-- Reservations survive cancelled waiters. A lease releases its credits at
-- most once, including after 'closeAdmission'. This is payload accounting,
-- not an RSS limit or a complete Runtime supervisor.
module LibTmux.Internal.Budget
  ( -- * Shared context
    Budget, Usage (..), newBudget, usage, closeAdmission
    -- * Reservations
  , ClientLease, ChildLease, ByteLease, acquireClient, acquireChild, acquireBytes
    -- * Retirement
  , releaseClient, releaseChild, releaseBytes
    -- * Admission failures
  , Resource (..), LimitError (..)
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception)
import Control.Monad (unless, when)
import Data.Word (Word64)

newtype Budget = Budget (TVar Usage)

data Usage = Usage
  { accepting :: !Bool
  , clients :: !Word64
  , children :: !Word64
  , pendingBytes :: !Word64
  }
  deriving stock (Eq, Show)

data Resource = Clients | Children | PendingBytes
  deriving stock (Eq, Show)

-- | Rejected admission. Exhaustion records resource, requested amount,
-- current usage and limit. Failed reservations change no counters.
data LimitError
  = AdmissionClosed
  | Exhausted !Resource !Word64 !Word64 !Word64
  deriving stock (Eq, Show)
instance Exception LimitError

-- The context keeps counters, not a registry of released tokens.
data Lease = Lease !Budget !(TVar Bool) !Word64 !Word64 !Word64
newtype ClientLease = ClientLease Lease
newtype ChildLease = ChildLease Lease
newtype ByteLease = ByteLease Lease

-- | Start an independent context: eight clients, sixteen children and
-- 128 MiB of pending payload reservations.
newBudget :: IO Budget
newBudget = Budget <$> newTVarIO (Usage True 0 0 0)

-- | Observe all counters in one transaction; no external resources are read.
usage :: Budget -> STM Usage
usage (Budget state) = readTVar state

-- | Reject future reservations without releasing existing leases or waiting
-- for cleanup. Owners must still call their corresponding release operation.
closeAdmission :: Budget -> STM ()
closeAdmission (Budget state) = modifyTVar' state (\old -> old {accepting = False})

-- | Reserve one client until its pin cleanup succeeds. Release with
-- 'releaseClient'; closed/exhausted contexts throw 'LimitError' in STM.
acquireClient :: Budget -> STM ClientLease
acquireClient budget = ClientLease <$> reserve budget 1 0 0

-- | Reserve one child and its byte allowance atomically. Neither credit
-- changes on failure. Retain until physical retirement; see 'releaseChild'.
acquireChild :: Budget -> Word64 -> STM ChildLease
acquireChild budget bytes = ChildLease <$> reserve budget 0 1 bytes

-- | Reserve retained payload capacity independently of a child. An internal
-- consumer keeps this lease through decoding or charged ownership transfer.
-- Release with 'releaseBytes'. Zero bytes still require open admission.
acquireBytes :: Budget -> Word64 -> STM ByteLease
acquireBytes budget bytes = ByteLease <$> reserve budget 0 0 bytes

reserve :: Budget -> Word64 -> Word64 -> Word64 -> STM Lease
reserve budget@(Budget state) clientDelta childDelta byteDelta = do
  old <- readTVar state
  unless old.accepting (throwSTM AdmissionClosed)
  checkLimit Clients clientDelta old.clients 8
  checkLimit Children childDelta old.children 16
  checkLimit PendingBytes byteDelta old.pendingBytes (128 * 1024 * 1024)
  live <- newTVar True
  writeTVar state $! old
    { clients = old.clients + clientDelta
    , children = old.children + childDelta
    , pendingBytes = old.pendingBytes + byteDelta
    }
  pure (Lease budget live clientDelta childDelta byteDelta)

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
release (Lease (Budget state) live clientDelta childDelta byteDelta) = do
  active <- readTVar live
  when active $ do
    old <- readTVar state
    writeTVar state $! old
      { clients = old.clients - clientDelta
      , children = old.children - childDelta
      , pendingBytes = old.pendingBytes - byteDelta
      }
    writeTVar live False
