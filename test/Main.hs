module Main (main) where

import BudgetTest qualified
import SchedulerTest qualified
import FrameTest qualified
import FieldTest qualified
import RecordTest qualified
import GraphTest qualified
import GraphProperties qualified
import QueryTest qualified
import QueryProperties qualified
import CommandTest qualified
import CreationTest qualified
import VersionProbeTest qualified
import TopologyTest qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "libtmux" [SchedulerTest.tests, BudgetTest.tests, FrameTest.tests, FieldTest.tests, RecordTest.tests, GraphTest.tests, GraphProperties.tests, TopologyTest.tests, QueryTest.tests, QueryProperties.tests, CommandTest.tests, CreationTest.tests, VersionProbeTest.tests])
