-- | Build validated detached snapshots for pure application tests.
--
-- No operation in this module contacts tmux. Named fixture references can
-- model successive observations; they never equal a live Server generation.
-- Snapshot and live-reference constructors remain hidden.
-- Validation checks graph and metadata laws; wire decoding, tmux normalization
-- and transport limits belong to acquisition rather than fixture construction.
--
-- Start with 'fixtureOrigin' and 'emptyFixture', construct ordinary observation
-- records using this module's reference builders, then call 'validateFixture'.
module LibTmux.Snapshot.Fixture
  ( -- * Offline identity
    FixtureOrigin, fixtureOrigin, fixtureGeneration, sessionRef, windowRef, paneRef
    -- * Complete fixture inputs
  , Fixture (..), AttachedClient (..), emptyFixture
    -- * Validation
  , FixtureError (..), validateFixture
  ) where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux.Id (PaneId, SessionId, WindowId)
import LibTmux.Internal.Graph qualified as G
import LibTmux.Snapshot
  ( Generation, Snapshot, ServerInfo (..), Session, SessionRef, Window, WindowRef
  , Pane, PaneRef, WindowLink
  )
import LibTmux.Value (WindowIndex)
import LibTmux.Version (TmuxVersion)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)
import System.OsString.Posix qualified as Os

-- | A named offline namespace. Equal names deliberately compare equal, so
-- tests can model successive observations. This cannot represent a Server.
newtype FixtureOrigin = FixtureOrigin Generation
  deriving stock (Eq, Ord, Show)

-- | Select a pure fixture namespace. No endpoint lookup or random IO occurs.
fixtureOrigin :: Text -> FixtureOrigin
fixtureOrigin = FixtureOrigin . G.FixtureGeneration

-- | The offline generation for t'Fixture' metadata. Replacing it with a connection
-- generation causes 'validateFixture' to reject the metadata.
fixtureGeneration :: FixtureOrigin -> Generation
fixtureGeneration (FixtureOrigin generation) = generation

-- | Construct a session reference that belongs only to this offline origin.
sessionRef :: FixtureOrigin -> SessionId -> SessionRef
sessionRef origin = G.SessionRef (fixtureGeneration origin)

-- | Construct a physical window reference without granting live authority.
windowRef :: FixtureOrigin -> WindowId -> WindowRef
windowRef origin = G.WindowRef (fixtureGeneration origin)

-- | Construct a pane reference without consulting or targeting a daemon.
paneRef :: FixtureOrigin -> PaneId -> PaneRef
paneRef origin = G.PaneRef (fixtureGeneration origin)

-- | Ordinary finite inputs. Validation applies the captured graph's laws;
-- record construction or updates alone do not establish those laws.
data Fixture = Fixture
  { info :: !ServerInfo -- ^ Synthetic metadata in the supplied offline generation.
  , sessions :: ![Session] -- ^ Physical sessions, with references from this origin.
  , windows :: ![Window] -- ^ Physical windows, independent of contextual appearances.
  , panes :: ![Pane] -- ^ Physical panes with their containing window references.
  , windowLinks :: ![WindowLink] -- ^ Session/index/window appearances, including active selections.
  , clients :: ![AttachedClient] -- ^ Complete attached-client listing for this fixture.
  }
  deriving stock (Eq, Show)

-- | An attached client's native identity and context before graph validation.
-- Validation resolves its values from the same snapshot; it never trusts a
-- caller-supplied nested attachment record.
data AttachedClient = AttachedClient
  { name :: !PosixString -- ^ Nonempty reported client-name bytes.
  , pid :: !Integer -- ^ Positive synthetic client PID in the native PID range.
  , tty :: !(Maybe PosixPath) -- ^ Nonempty terminal path when provided.
  , session :: !SessionId -- ^ Attachment session ID.
  , window :: !WindowId -- ^ Selected physical window ID.
  , index :: !WindowIndex -- ^ Selected window-link index in the attachment session.
  , pane :: !PaneId -- ^ The selected physical pane, not an independent client focus.
  }
  deriving stock (Eq, Show)

-- | Empty complete inputs with explicit synthetic metadata: PID 1, epoch 0
-- and path @fixture:offline@. No process or socket exists by implication.
-- The version and every edited field are checked by 'validateFixture'.
emptyFixture :: FixtureOrigin -> TmuxVersion -> Fixture
emptyFixture origin version = Fixture
  (ServerInfo (fixtureGeneration origin) 1 0 version (Os.fromBytestring "fixture:offline"))
  [] [] [] [] []

-- | A failed graph or complete-snapshot validation, with domain
-- context from the validator. Failed input never becomes an empty snapshot.
data FixtureError
  = InvalidGraph !Text -- ^ Invalid references, multiplicity, attachment counts or selections.
  | InvalidSnapshot !Text -- ^ Invalid metadata or attached-client context.
  deriving stock (Eq, Show)

-- | Validate and force owned values using the capture graph's invariants.
-- Successful fixtures have no acquisition interval and carry offline
-- provenance. Their references cannot equal references from a Server scope.
validateFixture :: FixtureOrigin -> Fixture -> Either FixtureError Snapshot
validateFixture origin input = do
  graph <- first (InvalidGraph . Text.pack . show) $
    G.assembleEntityGraph (fixtureGeneration origin)
      input.sessions input.windows input.panes input.windowLinks
  let clients =
        [ G.ClientInput row.name row.pid row.tty row.session row.window row.index row.pane
        | row <- input.clients
        ]
  first (InvalidSnapshot . Text.pack . show) (G.assembleSnapshot input.info graph clients)
