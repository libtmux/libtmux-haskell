module Main (main) where

import FrameTest qualified
import GraphTest qualified
import GraphProperties qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "libtmux" [FrameTest.tests, GraphTest.tests, GraphProperties.tests])
