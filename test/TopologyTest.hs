module TopologyTest (tests) where

import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Either (isLeft)
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Topology qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "numeric entity topology"
  [ testCase "normalizes physical entities and preserves repeated window links" $ do
      graph <- require (T.decodeTopology generation linked)
      length (G.graphSessions graph) @?= 1
      length (G.graphWindows graph) @?= 1
      length (G.graphPanes graph) @?= 1
      length (G.graphLinks graph) @?= 2
      length (G.graphOccurrences graph) @?= 2
      map (.active) (G.graphLinks graph) @?= [False, True]
  , testCase "accepts an empty daemon without inventing a session" $ do
      graph <- require (T.decodeTopology generation "")
      G.graphSessions graph @?= []
      G.graphOccurrences graph @?= []
  , testCase "rejects malformed numeric rows and inconsistent repetitions" $ do
      let bad =
            [ "S\t$0\t0"
            , "S\t$0\t-1\n"
            , "S\t$4294967296\t0\n"
            , linked <> "P\t@0\t%0\t0\t81\t24\t1\t0\n"
            , linked <> "W\t$0\t@0\t4\t0\t80\t24\n"
            , "S\t$0\t0\nW\t$0\t@0\t0\t2\t80\t24\n"
            , "S\t$0\t0\nW\t$0\t@0\t0\t1\t0\t24\n"
            , "P\t@0\t%0\t0\t80\t24\t1\t0\n"
            , "S\t$0\t0\nunknown\n"
            ]
      mapM_ (\wire -> assertBool (show wire) (isLeft (T.decodeTopology generation wire))) bad
  , testCase "limits wire bytes and unique entities before graph validation" $ do
      assertBool "oversized topology admitted" (isLeft
        (T.decodeTopology generation (Bytes.replicate (1024 * 1024 + 1) 48)))
      let sessions = Ascii.concat ["S\t$" <> Ascii.pack (show n) <> "\t0\n" | n <- [0..10000 :: Int]]
      T.decodeTopology generation sessions @?= Left (T.TopologyEntityLimit 10001)
  ]

generation :: G.Generation
generation = G.Generation (G.EndpointIdentity 1 2) (Bytes.replicate 32 3)

linked :: Bytes.ByteString
linked = "S\t$0\t0\nW\t$0\t@0\t0\t0\t80\t24\nP\t@0\t%0\t0\t80\t24\t1\t0\n"
  <> "W\t$0\t@0\t4\t1\t80\t24\nP\t@0\t%0\t0\t80\t24\t1\t0\n"

require :: Show e => Either e a -> IO a
require = either (fail . show) pure
