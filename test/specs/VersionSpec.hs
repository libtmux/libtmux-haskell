module VersionSpec (spec) where

import Data.Either (isLeft)
import LibTmux.Version
import Test.Hspec

spec :: Spec
spec = describe "tmux version admission" $ do
  it "accepts every required stable release" $
    mapM_ (\raw -> fmap renderVersion (parseVersion raw >>= requireSupported) `shouldBe` Right raw)
      ["3.3", "3.3a", "3.4", "3.5", "3.5a", "3.6", "3.6a", "3.6b", "3.7", "3.7a", "3.7b", "3.7c", "3.8"]
  it "parses tmux output without admitting a second line" $ do
    fmap renderVersion (parseVersion "tmux 3.3a\n") `shouldBe` Right "3.3a"
    parseVersion "tmux 3.3\n3.8" `shouldSatisfy` isLeft
  it "orders numeric components before suffixes" $
    case traverse parseVersion ["3.3", "3.3a", "3.3b", "3.9", "3.10", "4.0"] of
      Left problem -> expectationFailure (show problem)
      Right versions -> and (zipWith (<) versions (drop 1 versions)) `shouldBe` True
  it "rejects releases below plain 3.3" $
    mapM_ (\raw -> case parseVersion raw of
      Left problem -> expectationFailure ("valid old release failed parsing: " <> show problem)
      Right version -> requireSupported version `shouldBe` Left (UnsupportedVersion version))
      ["1.9", "2.9a", "3.0", "3.2a"]
  it "rejects malformed or development version claims" $
    mapM_ (\raw -> parseVersion raw `shouldSatisfy` isLeft)
      ["", "next-3.8", "3.8-rc1", "3.8a-next", "3.3aa", "3.3A", "3", "3.3.0", "03.3", "3.-3", "3.3 ", "tmux 3.3\n\n", "3.３"]
