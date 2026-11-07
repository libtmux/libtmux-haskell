module GraphProperties (tests) where

import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import LibTmux.Id
import LibTmux.Internal.Graph
import LibTmux.Value
import Test.Tasty (TestTree)
import Test.Tasty.QuickCheck qualified as Q

tests :: TestTree
tests = Q.testProperty "every contextual link retains every physical pane" $
  Q.checkCoverage $ Q.forAllShrink generator shrinkCounts $ \(links, panes) ->
    Q.cover 5 (panes == 1) "single pane" $
    case makeGraph links panes of
      Left problem -> Q.counterexample problem False
      Right graph ->
        let actual = map (\occurrence ->
              let PaneRef _ paneId = occurrence.pane.ref
              in (paneIdValue paneId, windowIndexValue occurrence.link.index)) (graphOccurrences graph)
            expected = [(fromIntegral pane, fromIntegral link) | link <- [0 .. links - 1], pane <- [0 .. panes - 1]]
        in Q.conjoin
          [ length (graphWindows graph) Q.=== 1
          , length (graphPanes graph) Q.=== panes
          , length (graphLinks graph) Q.=== links
          , actual Q.=== expected
          ]
  where
    generator = (,) <$> Q.chooseInt (2, 8) <*> Q.chooseInt (1, 8)
    shrinkCounts = filter (\(links, panes) -> links >= 2 && panes >= 1) . Q.shrink

makeGraph :: Int -> Int -> Either String EntityGraph
makeGraph linkCount paneCount = do
  let generation = Generation (EndpointIdentity 7 11) (Bytes.replicate 32 1)
  session <- SessionRef generation <$> checked (parseSessionId "$1")
  window <- WindowRef generation <$> checked (parseWindowId "@1")
  width <- checked (mkDimension 120)
  height <- checked (mkDimension 40)
  panes <- traverse (\index -> do
    ref <- PaneRef generation <$> checked (parsePaneId ("%" <> Text.pack (show index)))
    paneIndex <- checked (mkPaneIndex (fromIntegral index))
    pure (Pane ref window paneIndex width height (index == 0) False "pane" "cat" "/work")) [0 .. paneCount - 1]
  links <- traverse (\index -> do
    windowIndex <- checked (mkWindowIndex (fromIntegral index))
    pure (WindowLink session windowIndex window (index == 0))) [0 .. linkCount - 1]
  checked (assembleEntityGraph generation [Session session "work" 0]
    [Window window "editor" width height] panes links)

checked :: Show e => Either e a -> Either String a
checked = either (Left . show) Right
