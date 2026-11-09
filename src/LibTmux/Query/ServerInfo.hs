-- | Captured daemon metadata for "LibTmux.Query".
--
-- The tmux 3.3a baseline supplies one t'ServerInfo' per complete snapshot.
-- PID and start time are diagnostics, not a replacement for generation-bound
-- references or proof of present liveness.
module LibTmux.Query.ServerInfo (pid, startedAt, version, socketPath) where

import LibTmux.Internal.Field qualified as F
import LibTmux.Query (Field)
import LibTmux.Snapshot (ServerInfo)
import LibTmux.Version (TmuxVersion)
import System.OsPath.Posix (PosixPath)

-- | Observed daemon process ID.
pid :: Field ServerInfo Integer
pid = F.ServerPid

-- | Daemon start time in epoch seconds, as reported by tmux.
startedAt :: Field ServerInfo Integer
startedAt = F.ServerStartedAt

-- | Parsed tmux release, compared using the library's version ordering.
version :: Field ServerInfo TmuxVersion
version = F.ServerVersion

-- | Reported socket path on the tmux endpoint, retaining POSIX bytes.
socketPath :: Field ServerInfo PosixPath
socketPath = F.ServerSocketPath
