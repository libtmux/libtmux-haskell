-- | Named entries in the tmux daemon's global or session environment.
module LibTmux.Environment
  ( EnvironmentScope (..), EnvironmentVisibility (..), EnvironmentEntry (..)
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import LibTmux.Snapshot (SessionRef)

-- | Select the table itself. A session lookup does not fall back to global.
data EnvironmentScope = GlobalEnvironment | SessionEnvironment !SessionRef
  deriving stock (Eq, Show)

-- | Hidden entries are kept in tmux and omitted when it spawns processes.
data EnvironmentVisibility = Visible | Hidden
  deriving stock (Eq, Show)

instance NFData EnvironmentVisibility where
  rnf visibility = visibility `seq` ()

-- | Literal bytes or a removal marker. An empty value is present.
-- A removal marker stops an inherited value from reaching a new process.
data EnvironmentEntry
  = EnvironmentValue !EnvironmentVisibility !ByteString
  | EnvironmentRemoved !EnvironmentVisibility
  deriving stock (Eq)
