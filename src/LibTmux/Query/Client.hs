-- | Captured tmux client fields for "LibTmux.Query".
--
-- t'Client' means an observed tmux client, not the operational Server handle.
-- The tmux 3.3a baseline captures attached clients. 'tty' can be
-- absent for a control client; bytes retain endpoint path semantics.
module LibTmux.Query.Client (name, pid, tty, attachment) where

import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToOptional)
import LibTmux.Snapshot (Client, ClientAttachment)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)

-- | Lossless client name supplied by tmux.
name :: Field Client PosixString
name = F.ClientName

-- | Positive operating-system process ID, for observation rather than signalling.
pid :: Field Client Integer
pid = F.ClientPid

-- | Observed client tty, or 'Nothing' when tmux reports no tty.
tty :: Field Client (Maybe PosixPath)
tty = F.ClientTty

-- | Optional captured selection, used with 'LibTmux.Query.optionalRelated'. Absence fails
-- that positive predicate and satisfies its negation.
attachment :: ToOptional Client ClientAttachment
attachment = Q.ClientAttachment
