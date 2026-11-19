-- | Checked creation options, explicit link context and historical identities.
--
-- "LibTmux.Server" executes creation in IO through an existing pinned handle.
-- Start from 'defaultSessionOptions', 'defaultWindowOptions' or
-- 'defaultSplitOptions'; option fields perform no IO.
--
-- A t'CreatedEntities' contains the actual references printed by tmux before
-- after-hooks. It remains usable after the Server closes, but proves neither
-- current liveness nor successful process exec. Acquire a fresh snapshot and
-- use "LibTmux.Snapshot" to observe those identities again.
module LibTmux.Creation
  ( SessionOptions (..), InitialProcess (..), defaultSessionOptions
  , WindowSlot (..), WindowPlacement (..), WindowCollision (..)
  , WindowOptions (..), defaultWindowOptions
  , SplitDirection (..), SplitSize (..), SplitOptions (..), defaultSplitOptions
  , CreatedEntities (session, window, pane, windowIndex, serverPid)
  , CreatedSession, CreatedWindow, CreatedPane
  ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import LibTmux.Internal.Graph (CreatedEntities (..), CreatedSession, SessionRef)
import LibTmux.Snapshot (TmuxText)
import LibTmux.Value (Dimension, WindowIndex)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)

-- | Initial pane process, retaining tmux's distinct execution modes.
-- A native argv needs at least one argument after the executable because tmux
-- treats a single entry as shell input. 'DirectCommand' encodes that condition.
data InitialProcess
  = DefaultProcess -- ^ Use tmux's configured default-command or default shell.
  | ShellCommand !ByteString -- ^ Run command bytes through tmux's default shell.
  | DirectCommand !PosixString !(NonEmpty PosixString) -- ^ Execute the program and argv directly.
  deriving stock (Eq)

-- | Checked when creation is requested. Nothing selects native defaults.
-- Names and paths remain literal through tmux format parsing. Environment and
-- shell/argv bytes retain their native interpretation. Options have no Show
-- instance because command and environment data may contain credentials.
data SessionOptions = SessionOptions
  { name :: !(Maybe Text) -- ^ Literal session name, or tmux's generated name.
  , windowName :: !(Maybe TmuxText) -- ^ Literal initial window label; the daemon validates its bytes.
  , workingDirectory :: !(Maybe PosixPath) -- ^ Initial cwd, relative to the calling client's cwd when relative.
  , environment :: ![(PosixString, PosixString)] -- ^ Session overrides, subject to native environment inheritance.
  , width :: !(Maybe Dimension) -- ^ Requested cells, at most 65535; native status/layout rules still apply.
  , height :: !(Maybe Dimension) -- ^ Requested cells, at most 65535; independent of 'width'.
  , updateEnvironment :: !Bool -- ^ Apply tmux's configured update-environment list from the calling client.
  , process :: !InitialProcess -- ^ Initial process mode, separate from creation completion.
  } deriving stock (Eq)

-- | Detached creation with generated names, native geometry/environment and
-- 'DefaultProcess'. Creation captures the calling client's OS context in IO.
defaultSessionOptions :: SessionOptions
defaultSessionOptions = SessionOptions Nothing Nothing Nothing [] Nothing Nothing True DefaultProcess

-- | An exact session/index position at execution time. The occupant can change
-- after a snapshot; this is context, not an expected-window identity check.
-- 'LibTmux.Server.splitPane' also checks its explicit pane belongs to the
-- window occupying this slot. Indices must fit tmux's signed 32-bit domain.
data WindowSlot = WindowSlot !SessionRef !WindowIndex
  deriving stock (Eq, Show)

-- | A session's next free index, an exact slot, or insertion beside a slot.
-- Relative insertion can shift existing indices before later creation fails;
-- failure does not promise rollback. Grouped sessions can share these effects.
-- If a relative slot is vacant, tmux creates at that index without insertion.
data WindowPlacement
  = NextFree !SessionRef -- ^ Let tmux choose a free index from the session's base-index.
  | At !WindowSlot -- ^ Create at the exact index, subject to 'WindowCollision'.
  | Before !WindowSlot -- ^ Insert before this slot's current occupant.
  | After !WindowSlot -- ^ Insert after this slot's current occupant.
  deriving stock (Eq, Show)

-- | Occupied-slot policy for creation. Replacement removes the old link;
-- other links can keep its physical window alive. Later failure can follow
-- removal. Replacing the selected link can select the new window despite @-d@.
data WindowCollision = RefuseOccupied | ReplaceOccupied
  deriving stock (Eq, Show)

-- | Window creation through an explicit placement. Names and cwd stay literal;
-- environment and process bytes keep tmux's native interpretation. Geometry
-- comes from the target session. tmux may normalize or reject the name.
-- Options carry no Show instance because launch data can contain credentials.
data WindowOptions = WindowOptions
  { name :: !(Maybe TmuxText) -- ^ Literal label, or tmux's generated name.
  , workingDirectory :: !(Maybe PosixPath) -- ^ Initial cwd; a relative path uses the caller's cwd.
  , environment :: ![(PosixString, PosixString)] -- ^ Overrides for the new pane, not the session environment.
  , select :: !Bool -- ^ Request selection of the new link in its target session.
  , collision :: !WindowCollision -- ^ Refuse or explicitly remove an occupied destination link.
  , process :: !InitialProcess -- ^ Initial pane process; completion does not prove exec success.
  } deriving stock (Eq)

-- | Generated name, native geometry/cwd/environment, no selection request,
-- 'RefuseOccupied' and 'DefaultProcess'.
defaultWindowOptions :: WindowOptions
defaultWindowOptions = WindowOptions Nothing Nothing [] False RefuseOccupied DefaultProcess

-- | Orientation of the two resulting panes. 'before' chooses the left or top
-- side for the new pane; otherwise it appears right or below the anchor.
data SplitDirection = LeftRight | TopBottom
  deriving stock (Eq, Show)

-- | Requested extent of the new pane along the split direction. Cells must fit
-- 2147483647 and percentages must be between 1 and 100. tmux's border and layout
-- constraints determine the actual size; a request can be clamped or refused.
data SplitSize = DefaultSplitSize | SplitCells !Dimension | SplitPercent !Integer
  deriving stock (Eq, Show)

-- | Split one exact pane through an explicit 'WindowSlot'. The pane must occupy
-- that slot's physical window when tmux executes the request. No active-pane
-- lookup, reuse or replacement occurs. Launch fields follow 'WindowOptions'.
data SplitOptions = SplitOptions
  { direction :: !SplitDirection -- ^ Left/right or top/bottom geometry.
  , size :: !SplitSize -- ^ New pane's requested extent; default is tmux's half split.
  , before :: !Bool -- ^ Put the new pane left or above the anchor.
  , fullWindow :: !Bool -- ^ Span the window across the perpendicular dimension.
  , select :: !Bool -- ^ Request selection of the new pane; independent of session link selection.
  , zoom :: !Bool -- ^ Zoom the window, or keep it zoomed when already zoomed.
  , workingDirectory :: !(Maybe PosixPath) -- ^ Explicit initial cwd, literal through format parsing.
  , environment :: ![(PosixString, PosixString)] -- ^ Overrides for the new pane.
  , process :: !InitialProcess -- ^ Initial pane process, independent of creation completion.
  } deriving stock (Eq)

-- | Split below the exact anchor without selection, full-window or zoom
-- requests. Use tmux's size and launch defaults.
defaultSplitOptions :: SplitOptions
defaultSplitOptions = SplitOptions TopBottom DefaultSplitSize False False False False Nothing [] DefaultProcess

-- | A 'CreatedEntities' receipt from new-window: the window and pane are new;
-- the session and link index identify where tmux created them.
type CreatedWindow = CreatedEntities

-- | A 'CreatedEntities' receipt from split-window: the pane is new; its session,
-- physical window and link index record the exact execution context.
type CreatedPane = CreatedEntities
