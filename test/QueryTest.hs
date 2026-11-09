module QueryTest (tests) where

import LibTmux.Internal.Query qualified as Q
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "query-cardinality"
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
