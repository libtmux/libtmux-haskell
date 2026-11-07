module Main (main) where

import FixtureTest qualified
import FrameIntegrationTest qualified
import SocketPinTest qualified
import ProcessTest qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = ProcessTest.withTests $ \processTests -> defaultMain $
  testGroup "real tmux" [FixtureTest.tests, FrameIntegrationTest.tests, SocketPinTest.tests, processTests]
