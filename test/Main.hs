module Main (main) where

import BudgetTest qualified
import FrameTest qualified
import GraphTest qualified
import GraphProperties qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "libtmux" [BudgetTest.tests, FrameTest.tests, GraphTest.tests, GraphProperties.tests])
