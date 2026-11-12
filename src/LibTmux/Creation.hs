-- | Options and historical identities for detached session creation.
--
-- "LibTmux.Server" executes creation in IO through an existing pinned handle.
-- Start from 'defaultSessionOptions'; ordinary record updates select names,
-- geometry, environment and the initial process. Option fields perform no IO.
--
-- A t'CreatedSession' contains the actual references printed by tmux before
-- after-hooks. It remains usable after the Server closes, but proves neither
-- current liveness nor successful process exec. Acquire a fresh snapshot and
-- use "LibTmux.Snapshot" to observe those identities again.
module LibTmux.Creation
  ( SessionOptions (..), InitialProcess (..), defaultSessionOptions
  , CreatedSession (session, window, pane, windowIndex, serverPid)
  ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import LibTmux.Internal.Graph (CreatedSession (..))
import LibTmux.Snapshot (TmuxText)
import LibTmux.Value (Dimension)
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
