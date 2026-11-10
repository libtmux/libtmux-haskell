-- | Physical pane fields and its required window relationship.
--
-- Use these tokens with "LibTmux.Query"; each describes an owned t'Pane'
-- from "LibTmux.Snapshot". All are available in the tmux 3.3a baseline.
-- Text comparisons are exact. Command and path values retain POSIX bytes
-- from the endpoint rather than promising UTF-8 or local path semantics.
module LibTmux.Query.Pane
  ( id, windowId, index, width, height, active, dead, title, currentCommand
  , currentPath, window
  ) where

import Prelude hiding (id)
import Data.Text (Text)
import LibTmux.Id (PaneId, WindowId)
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToOne)
import LibTmux.Snapshot (Pane, Window)
import LibTmux.Value (Dimension, PaneIndex)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)

-- | Native pane ID. Equality alone does not establish Server identity.
id :: Field Pane PaneId
id = F.PaneId

-- | Native ID of the pane's physical window; use 'window' to navigate it.
windowId :: Field Pane WindowId
windowId = F.PaneWindow

-- | Pane index within its window, distinct from a window-link index.
index :: Field Pane PaneIndex
index = F.PaneIndex

-- | Positive width in cells. Use 'LibTmux.Query.dimensionAtLeast' for an integer threshold.
width :: Field Pane Dimension
width = F.PaneWidth

-- | Positive height in cells, independent of window-link context.
height :: Field Pane Dimension
height = F.PaneHeight

-- | Whether this is the active pane of its physical window.
active :: Field Pane Bool
active = F.PaneActive

-- | Whether tmux observed the pane's process as dead.
dead :: Field Pane Bool
dead = F.PaneDead

-- | UTF-8 pane title. 'LibTmux.Query.contains' performs exact Text substring matching.
title :: Field Pane Text
title = F.PaneTitle

-- | Foreground command name as lossless POSIX bytes, not a shell command line.
currentCommand :: Field Pane PosixString
currentCommand = F.PaneCommand

-- | Observed current directory on the tmux endpoint, preserving POSIX bytes.
currentPath :: Field Pane PosixPath
currentPath = F.PanePath

-- | Resolve the pane's physical window in the supplied snapshot with 'LibTmux.Query.related'.
window :: ToOne Pane Window
window = Q.PaneWindow
