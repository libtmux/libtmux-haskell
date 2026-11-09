module QueryTest (tests) where

import Data.Set qualified as Set
import Data.Text (Text)
import LibTmux.Id qualified as Id
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Graph qualified as Pane (Pane (..))
import LibTmux.Internal.Query qualified as Q
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as V
import LibTmux.Version qualified as Version
import QueryFixture qualified as Fixture
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "queries" [cardinalityTests, evaluatorTests]

cardinalityTests :: TestTree
cardinalityTests = testGroup "query-cardinality"
  [ testCase "exactlyOne distinguishes absent, unique and ambiguous matches" $ do
      Q.exactlyOne ([] :: [Int]) @?= Left Q.NoMatches
      Q.exactlyOne [7 :: Int] @?= Right 7
      Q.exactlyOne [7 :: Int, 8] @?= Left Q.AtLeastTwoMatches
      Q.exactlyOne (filter (> 0) [0 :: Int, 0, 7, 0, 0]) @?= Right 7
      Q.exactlyOne (filter (> 0) [0 :: Int, 7, 0, 8]) @?= Left Q.AtLeastTwoMatches
  , testCase "atMostOne permits absence and rejects ambiguity" $ do
      Q.atMostOne ([] :: [Int]) @?= Right Nothing
      Q.atMostOne [7 :: Int] @?= Right (Just 7)
      Q.atMostOne [7 :: Int, 8] @?= Left Q.AtLeastTwoMatches
  , testCase "ambiguous selection does not count the remaining tail" $ do
      let matches = (7 :: Int) : 8 : error "ambiguous tail was forced"
      Q.exactlyOne matches @?= Left Q.AtLeastTwoMatches
      Q.atMostOne matches @?= Left Q.AtLeastTwoMatches
  ]

evaluatorTests :: TestTree
evaluatorTests = testGroup "typed query evaluation"
  [ testCase "typed scalar selection agrees with ordinary captured predicates" $ do
      snapshot <- checked Fixture.snapshot
      let selected = Q.matching (Q.allOf [Q.eq F.PaneActive True,
                         Q.dimensionAtLeast F.PaneWidth 120]) Q.panes
          native = filter (\pane -> pane.active && V.dimensionValue pane.width >= 120)
            (G.graphPanes (G.entities snapshot))
      Q.runQuery snapshot selected @?= Right native
      paneKeys (Q.runQuery snapshot selected) @?= Right ["%0", "%2"]
      paneKeys (Q.runQuery snapshot (Q.matching
        (Q.oneOf F.PaneCommand [Os.fromBytestring "ghci"]) Q.panes)) @?= Right ["%1"]
  , testCase "mathematical thresholds do not narrow checked values" $ do
      snapshot <- checked Fixture.snapshot
      let huge = 10 ^ (100 :: Int)
      paneKeys (Q.runQuery snapshot (Q.matching (Q.dimensionAtLeast F.PaneWidth (-1)) Q.panes))
        @?= Right ["%0", "%1", "%2"]
      Q.runQuery snapshot (Q.matching (Q.dimensionAtLeast F.PaneWidth huge) Q.panes) @?= Right []
      paneKeys (Q.runQuery snapshot (Q.matching (Q.dimensionAtMost F.PaneWidth huge) Q.panes))
        @?= Right ["%0", "%1", "%2"]
      paneKeys (Q.runQuery snapshot (Q.matching (Q.paneIndexAtLeast F.PaneIndex 1) Q.panes))
        @?= Right ["%1"]
      sessionKeys (Q.runQuery snapshot (Q.matching (Q.ge F.SessionAttached 1) Q.sessions)) @?= Right ["$0"]
      paneKeys (Q.runQuery snapshot (Q.limit (10 ^ (100 :: Int)) Q.panes)) @?= Right ["%0", "%1", "%2"]
  , testCase "text matching keeps normalization distinct and labels preserve bytes" $ do
      snapshot <- checked Fixture.snapshot
      paneKeys (Q.runQuery snapshot (Q.matching (Q.contains F.PaneTitle "\233") Q.panes)) @?= Right ["%0"]
      windowKeys (Q.runQuery snapshot (Q.matching
        (Q.eq F.WindowName (Label.fromBytes "bad\255")) Q.windows)) @?= Right ["@1"]
  , testCase "relationship predicates preserve same-child semantics" $ do
      snapshot <- checked Fixture.snapshot
      let active = Q.eq F.PaneActive True
          ghci = Q.eq F.PaneCommand (Os.fromBytestring "ghci")
          sameChild = Q.some Q.WindowPanes (Q.allOf [active, ghci])
          differentChildren = Q.allOf [Q.some Q.WindowPanes active, Q.some Q.WindowPanes ghci]
      Q.runQuery snapshot (Q.matching sameChild Q.windows) @?= Right []
      windowKeys (Q.runQuery snapshot (Q.matching differentChildren Q.windows)) @?= Right ["@0"]
      paneKeys (Q.runQuery snapshot (Q.matching
        (Q.related Q.PaneWindow (Q.eq F.WindowName "work")) Q.panes)) @?= Right ["%0", "%1"]
  , testCase "known empty relations follow quantifier laws" $ do
      snapshot <- checked Fixture.snapshot
      let anyChild = Q.allOf []
      sessionKeys (Q.runQuery snapshot (Q.matching (Q.some Q.SessionClients anyChild) Q.sessions))
        @?= Right ["$0"]
      sessionKeys (Q.runQuery snapshot (Q.matching (Q.every Q.SessionClients anyChild) Q.sessions))
        @?= Right ["$0", "$1"]
      sessionKeys (Q.runQuery snapshot (Q.matching (Q.none Q.SessionClients anyChild) Q.sessions))
        @?= Right ["$1"]
  , testCase "optional absence remains distinct from unavailable data" $ do
      snapshot <- checked Fixture.snapshot
      let detached = G.Client (Os.fromBytestring "unattached") 12 Nothing Nothing
          attached = Q.optionalRelated Q.ClientAttachment (Q.allOf [])
          native = Q.nativeProfile
          blocked = native {Q.availableFields = Set.delete "client.tty" native.availableFields}
      Q.evaluateExpr snapshot attached detached @?= Right False
      Q.evaluateExpr snapshot (Q.not_ attached) detached @?= Right True
      fmap length (Q.runQuery snapshot (Q.matching (Q.eq F.ClientTty Nothing) Q.clients)) @?= Right 1
      Q.runQueryWith blocked snapshot (Q.matching (Q.eq F.ClientTty Nothing) Q.clients)
        @?= Left (Q.FieldUnavailable "client.tty")
  , testCase "failed required navigation never becomes an empty relation" $ do
      snapshot <- checked Fixture.snapshot
      pane <- checked (Q.exactlyOne (take 1 (G.graphPanes (G.entities snapshot))))
      ident <- checked (Id.parseWindowId "@0")
      let foreignWindow = G.WindowRef (G.FixtureGeneration "another") ident
          edited = pane {Pane.window = foreignWindow}
      Q.evaluateExpr snapshot (Q.related Q.PaneWindow (Q.allOf [])) edited
        @?= Left (Q.RelationshipLookupFailed "pane.window" G.ForeignGeneration)
  , testCase "validation visits decisive branches, empty membership, ordering and limit zero" $ do
      snapshot <- checked Fixture.snapshot
      empty <- checked Fixture.emptySnapshot
      let native = Q.nativeProfile
          blocked = native {Q.availableFields = Set.delete "pane.active" native.availableFields}
          queries =
            [ Q.matching (Q.anyOf [Q.allOf [], Q.eq F.PaneActive True]) Q.panes
            , Q.matching (Q.oneOf F.PaneActive []) Q.panes
            , Q.orderBy [Q.ascending F.PaneActive] Q.panes
            , Q.limit 0 (Q.matching (Q.eq F.PaneActive True) Q.panes)
            ]
      mapM_ (\query -> do
        Q.runQueryWith blocked snapshot query @?= Left (Q.FieldUnavailable "pane.active")
        Q.runQueryWith blocked empty query @?= Left (Q.FieldUnavailable "pane.active")) queries
  , testCase "unavailable relationships fail even when no child is examined" $ do
      snapshot <- checked Fixture.emptySnapshot
      let native = Q.nativeProfile
          blocked = native {Q.availableRelationships = Set.delete "session.clients" native.availableRelationships}
          query = Q.matching (Q.anyOf [Q.allOf [], Q.some Q.SessionClients (Q.allOf [])]) Q.sessions
      Q.runQueryWith blocked snapshot query @?= Left (Q.RelationshipUnavailable "session.clients")
  , testCase "capability preparation uses parsed release ordering" $ do
      older <- checked (Version.parseVersion "3.3")
      minimumVersion <- checked (Version.parseVersion "3.3a")
      let native = Q.nativeProfile
          profile = native {Q.evaluatorVersion = Just older}
      Q.prepare profile (Q.matching (Q.eq F.PaneActive True) Q.panes)
        @?= Left (Q.RequiresTmux "pane.active" minimumVersion older)
  , testCase "filtering and stable ordering precede limits regardless of builder order" $ do
      snapshot <- checked Fixture.snapshot
      let limited = Q.limit 1 Q.panes
      paneKeys (Q.runQuery snapshot (Q.matching (Q.dimensionAtLeast F.PaneWidth 130) limited))
        @?= Right ["%2"]
      paneKeys (Q.runQuery snapshot (Q.orderBy [Q.descending F.PaneWidth] limited)) @?= Right ["%2"]
      paneKeys (Q.runQuery snapshot (Q.orderBy [Q.ascending F.PaneDead] Q.panes))
        @?= Right ["%0", "%1", "%2"]
      paneKeys (Q.runQuery snapshot (Q.orderBy [Q.descending F.PaneActive] Q.panes))
        @?= Right ["%0", "%2", "%1"]
  , testCase "physical rows and contextual occurrences keep different cardinality" $ do
      snapshot <- checked Fixture.snapshot
      ident <- checked (Id.parsePaneId "%0")
      physical <- checked (Q.runQuery snapshot (Q.matching (Q.eq F.PaneId ident) Q.panes))
      occurrences <- checked (Q.runQuery snapshot (Q.matching
        (Q.related Q.OccurrencePane (Q.eq F.PaneId ident)) Q.paneOccurrences))
      fmap paneKey (Q.exactlyOne physical) @?= Right "%0"
      Q.exactlyOne occurrences @?= Left Q.AtLeastTwoMatches
      fmap (map (paneKey . (.pane))) (Q.runQuery snapshot Q.paneOccurrences)
        @?= Right ["%0", "%1", "%0", "%1", "%2", "%2"]
  , testCase "dependency inspection includes nested and ordering fields" $ do
      let query = Q.limit 1 (Q.orderBy [Q.ascending F.PaneWidth]
            (Q.matching (Q.eq F.PaneActive True) Q.panes))
          required = Q.requirements query
          nested = Q.requirements (Q.matching
            (Q.some Q.WindowPanes (Q.eq F.PaneActive True)) Q.windows)
      required.sourceName @?= "panes"
      required.fieldNames @?= ["pane.active", "pane.width"]
      required.relationshipNames @?= []
      required.orderingFields @?= ["pane.width"]
      required.rowLimit @?= Just 1
      nested.fieldNames @?= ["pane.active"]
      nested.relationshipNames @?= ["window.panes"]
  ]

paneKey :: G.Pane -> Text
paneKey row = case row.ref of G.PaneRef _ ident -> Id.renderPaneId ident

paneKeys :: Either Q.QueryError [G.Pane] -> Either Q.QueryError [Text]
paneKeys = fmap (map paneKey)

windowKeys :: Either Q.QueryError [G.Window] -> Either Q.QueryError [Text]
windowKeys = fmap (map (\row -> case row.ref of G.WindowRef _ ident -> Id.renderWindowId ident))

sessionKeys :: Either Q.QueryError [G.Session] -> Either Q.QueryError [Text]
sessionKeys = fmap (map (\row -> case row.ref of G.SessionRef _ ident -> Id.renderSessionId ident))

checked :: Show problem => Either problem value -> IO value
checked = either (fail . show) pure
