-- | Run terminal applications through an owned scope. Use
-- 'LibTmux.Server.withProgram' for an interactive handle or
-- 'LibTmux.Server.runProgram' for a final result. These operations borrow the
-- selected daemon and own only their new session, application process group,
-- native command clients, pin, buffers and files.
--
-- A scope sends TERM, waits up to 100ms for leader exit, then sends group KILL
-- through a retained Linux pidfd.
-- Completed cleanup proves leader exit and an empty retained process group.
-- Zombies or uninterruptible members may leave a reachable cleanup recovery.
-- Processes that move to another process group/session escape this contract.
-- Linux 6.9 process-group pidfd signaling and a local daemon in the same PID
-- and filesystem namespaces are required. The selected 'bootstrapShell' must
-- provide Bash dynamic descriptors, timed reads and execfail. It defaults to
-- @\/bin\/bash@ and is probed before application creation. The gate has a
-- separate one-second startup lease; 'commandTimeout' bounds each native
-- command. Neither bounds whole startup: 'executionTimeout' bounds owning
-- setup and the callback. Cleanup wakes a blocked gate with an abort claim;
-- the descriptor closes before application exec.
-- The host operation and tmux 3.8 capability are checked before application
-- resources are created.
--
-- Output is a bounded rendered snapshot, not stdout/stderr byte streaming.
-- Controller-process crash recovery, persistent leases, readiness predicates,
-- keep/detach and MCP operations remain unimplemented. Use the scope while its
-- callback runs; detached t'ProgramResult' values survive cleanup.
module LibTmux.Program
  ( Program, ProgramOptions (..), programOptions
  , ProgramExit (..), StartFailure (..), StartPhase (..)
  , ProgramScreen (..), ProgramResult (..), ProgramError (..)
  , sendProgramInput, readProgramScreen, waitProgram, waitProgramFor, terminateProgram
  , ProgramRecovery, ProgramCleanupStatus (..), programRecoveries, programCleanupFailure
  , inspectProgramCleanup, resumeProgramCleanup
  ) where

import LibTmux.Internal.Program
