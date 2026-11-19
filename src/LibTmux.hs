-- | Capture tmux state in IO and process detached observations with ordinary
-- Haskell collections. Start with 'withServer' and 'capture'; navigation and
-- field access from "LibTmux.Snapshot" perform no external operations.
-- 'renameSession', 'renameWindow' and 'setPaneTitle' act on explicit references
-- in IO; detached observations change only when acquired again with 'capture'.
-- 'createSession', 'createWindow' and 'splitPane' return historical identities;
-- "LibTmux.Creation" describes their options and explicit link context.
-- Capture again for observations.
--
-- "LibTmux.Server" documents ownership and failure recovery. Typed IDs,
-- checked dimensions and release admission have their own pure modules.
-- "LibTmux.Query" provides qualified typed descriptions over the same
-- snapshots; query source names are separate from collection access here.
module LibTmux
  ( module LibTmux.Capabilities
  , module LibTmux.Creation
  , module LibTmux.Server
  , module LibTmux.Program
  , module LibTmux.Snapshot
  , module LibTmux.Id
  , module LibTmux.Value
  , module LibTmux.Version
  ) where

import LibTmux.Capabilities
import LibTmux.Creation
import LibTmux.Id
import LibTmux.Server
import LibTmux.Program
  ( Program, ProgramOptions, programOptions
  , ProgramExit (..), StartFailure (..), StartPhase (..)
  , ProgramScreen (..), ProgramResult (..), ProgramError (..)
  , sendProgramInput, readProgramScreen, waitProgram, waitProgramFor, terminateProgram
  , ProgramRecovery, ProgramCleanupStatus (..), programRecoveries, programCleanupFailure
  , inspectProgramCleanup, resumeProgramCleanup
  )
import LibTmux.Snapshot
import LibTmux.Value
import LibTmux.Version
