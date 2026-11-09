module FixtureSpec (spec) where

import Data.Either (isLeft)
import LibTmux qualified as Tmux
import LibTmux.Snapshot.Fixture qualified as F
import System.OsString.Posix qualified as Os
import Test.Hspec

spec :: Spec
spec = describe "validated offline fixtures" $ do
  it "retains physical identity, repeated appearances and offline provenance" $ do
    (origin, input) <- fixture
    snapshot <- checked (F.validateFixture origin input)
    Tmux.snapshotOrigin snapshot `shouldBe` Tmux.DefinedOffline "reports"
    Tmux.captureInterval snapshot `shouldBe` Nothing
    (length (Tmux.windows snapshot), length (Tmux.windowLinks snapshot)) `shouldBe` (1, 2)
    length (Tmux.paneOccurrences snapshot) `shouldBe` 2
    [Tmux.renderPaneId (Tmux.paneId row.ref) | row <- Tmux.panes snapshot,
      row.active, Tmux.dimensionValue row.width >= 120] `shouldBe` ["%3"]

  it "separates named origins at reference construction and lookup" $ do
    (origin, input) <- fixture
    snapshot <- checked (F.validateFixture origin input)
    ident <- checked (Tmux.parsePaneId "%3")
    let same = F.paneRef (F.fixtureOrigin "reports") ident
        other = F.paneRef (F.fixtureOrigin "other") ident
    same `shouldBe` F.paneRef origin ident
    same `shouldNotBe` other
    Tmux.lookupPane snapshot other `shouldBe` Left Tmux.ForeignGeneration
    F.validateFixture (F.fixtureOrigin "other") input `shouldSatisfy` isLeft
    let foreignInfo = input.info
          {Tmux.generation = F.fixtureGeneration (F.fixtureOrigin "other")}
    case F.validateFixture origin (input {F.info = foreignInfo}) of
      Left (F.InvalidSnapshot _) -> pure ()
      otherResult -> expectationFailure ("foreign metadata was accepted: " <> show otherResult)

  it "rejects duplicate slots and client context from an inactive appearance" $ do
    (origin, input) <- fixture
    case input.windowLinks of
      first : _ -> F.validateFixture origin (input {F.windowLinks = [first, first]})
        `shouldSatisfy` isLeft
      _ -> expectationFailure "test fixture has no window link"
    sid <- checked (Tmux.parseSessionId "$1")
    wid <- checked (Tmux.parseWindowId "@2")
    pid <- checked (Tmux.parsePaneId "%3")
    index <- checked (Tmux.mkWindowIndex 4)
    let client = F.AttachedClient (Os.fromBytestring "control-client") 7 Nothing sid wid index pid
    case F.validateFixture origin (input {F.clients = [client]}) of
      Left (F.InvalidSnapshot _) -> pure ()
      other -> expectationFailure ("inactive client context was not rejected: " <> show other)
    selected <- checked (Tmux.mkWindowIndex 0)
    snapshot <- checked (F.validateFixture origin (input {F.clients = [client {F.index = selected}]}))
    case Tmux.clients snapshot of
      [observed] -> case observed.attachment of
        Just attachment -> attachment.pane.link.index `shouldBe` selected
        Nothing -> expectationFailure "attached fixture client lost its context"
      _ -> expectationFailure "attached fixture client disappeared"

fixture :: IO (F.FixtureOrigin, F.Fixture)
fixture = do
  version <- checked (Tmux.parseVersion "3.8")
  sid <- checked (Tmux.parseSessionId "$1")
  wid <- checked (Tmux.parseWindowId "@2")
  pid <- checked (Tmux.parsePaneId "%3")
  width <- checked (Tmux.mkDimension 120)
  height <- checked (Tmux.mkDimension 40)
  paneIndex <- checked (Tmux.mkPaneIndex 0)
  first <- checked (Tmux.mkWindowIndex 0)
  second <- checked (Tmux.mkWindowIndex 4)
  let origin = F.fixtureOrigin "reports"
      session = Tmux.Session (F.sessionRef origin sid) "work" 0
      window = Tmux.Window (F.windowRef origin wid) "editor" width height
      pane = Tmux.Pane (F.paneRef origin pid) window.ref paneIndex width height True False "editor"
        (Os.fromBytestring "ghci") (Os.fromBytestring "/offline/project")
      input = (F.emptyFixture origin version)
        { F.sessions = [session], F.windows = [window], F.panes = [pane]
        , F.windowLinks = [Tmux.WindowLink session.ref first window.ref True,
                          Tmux.WindowLink session.ref second window.ref False]
        }
  pure (origin, input)

checked :: Show problem => Either problem value -> IO value
checked = either (fail . show) pure
