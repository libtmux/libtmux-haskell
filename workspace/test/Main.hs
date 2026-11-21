module Main (main) where

import ApplyTest qualified
import CatalogueTest qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "workspace" [CatalogueTest.tests, ApplyTest.tests])
