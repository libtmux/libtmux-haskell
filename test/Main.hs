module Main (main) where

import BudgetTest qualified
import SchedulerTest qualified
import FrameTest qualified
import GraphTest qualified
import GraphProperties qualified
import TopologyTest qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "libtmux" [SchedulerTest.tests, BudgetTest.tests, FrameTest.tests, GraphTest.tests, GraphProperties.tests, TopologyTest.tests])
