-- | Capture tmux state in IO and process detached observations with ordinary
-- Haskell collections. Start with 'withServer' and 'capture'; navigation and
-- field access from "LibTmux.Snapshot" perform no external operations.
--
-- "LibTmux.Server" documents ownership and failure recovery. Typed IDs,
-- checked dimensions and supported releases have their own pure modules.
-- "LibTmux.Query" provides qualified typed descriptions over the same
-- snapshots; query source names are separate from collection access here.
module LibTmux
  ( module LibTmux.Server
  , module LibTmux.Snapshot
  , module LibTmux.Id
  , module LibTmux.Value
  , module LibTmux.Version
  ) where

import LibTmux.Id
import LibTmux.Server
import LibTmux.Snapshot
import LibTmux.Value
import LibTmux.Version
