module QueryProperties (tests) where

import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Query qualified as Query
import LibTmux.Value qualified as V
import QueryFixture qualified as Fixture
import Test.Tasty (TestTree)
import Test.Tasty.QuickCheck qualified as Q

data Predicate
  = Active Bool | WidthAtLeast Integer | TitleContains Text
  | All [Predicate] | Any [Predicate] | Not Predicate
  deriving stock Show

tests :: TestTree
tests = Q.testProperty "typed query agrees with independent native predicates" $
  Q.checkCoverage $ Q.forAllShrink (generatePredicate 4) shrinkPredicate $ \predicate ->
    Q.cover 20 (compound predicate) "compound" $
    case Fixture.snapshot of
      Left problem -> Q.counterexample problem False
      Right snapshot ->
        Query.runQuery snapshot (Query.matching (typed predicate) Query.panes)
          Q.=== Right (filter (native predicate) (G.graphPanes (G.entities snapshot)))

generatePredicate :: Int -> Q.Gen Predicate
generatePredicate depth
  | depth <= 0 = leaf
  | otherwise = Q.frequency
      [ (5, leaf)
      , (1, Not <$> child)
      , (2, All <$> children)
      , (2, Any <$> children)
      ]
  where
    child = generatePredicate (depth - 1)
    children = Q.chooseInt (0, 3) >>= \size -> Q.vectorOf size child
    leaf = Q.oneof
      [ Active <$> Q.arbitrary
      , WidthAtLeast <$> Q.elements [-1, 0, 80, 120, 160, 10 ^ (100 :: Int)]
      , TitleContains <$> Q.elements ["", "other", "\233", "e\769", "missing"]
      ]

shrinkPredicate :: Predicate -> [Predicate]
shrinkPredicate = \case
  Active _ -> []
  WidthAtLeast value -> WidthAtLeast <$> Q.shrink value
  TitleContains value -> TitleContains . Text.pack <$> Q.shrink (Text.unpack value)
  All values -> values <> map All (Q.shrinkList shrinkPredicate values)
  Any values -> values <> map Any (Q.shrinkList shrinkPredicate values)
  Not value -> value : map Not (shrinkPredicate value)

compound :: Predicate -> Bool
compound = \case All _ -> True; Any _ -> True; Not _ -> True; _ -> False

typed :: Predicate -> Query.Expr G.Pane
typed = \case
  Active value -> Query.eq F.PaneActive value
  WidthAtLeast value -> Query.dimensionAtLeast F.PaneWidth value
  TitleContains value -> Query.contains F.PaneTitle value
  All values -> Query.allOf (map typed values)
  Any values -> Query.anyOf (map typed values)
  Not value -> Query.not_ (typed value)

native :: Predicate -> G.Pane -> Bool
native predicate pane = case predicate of
  Active value -> pane.active == value
  WidthAtLeast value -> V.dimensionValue pane.width >= value
  TitleContains value -> value `Text.isInfixOf` pane.title
  All values -> all (\value -> native value pane) values
  Any values -> any (\value -> native value pane) values
  Not value -> not (native value pane)
