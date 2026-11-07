module Main (main) where

import IdSpec qualified
import Test.Hspec (hspec)
import ValueSpec qualified
import VersionSpec qualified

main :: IO ()
main = hspec $ do
  VersionSpec.spec
  ValueSpec.spec
  IdSpec.spec
