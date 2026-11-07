module ValueSpec (spec) where

import LibTmux.Value
import Test.Hspec

spec :: Spec
spec = describe "checked scalar domains" $ do
  it "rejects nonpositive dimensions without narrowing integers" $ do
    mkDimension 0 `shouldBe` Left (NonPositiveDimension 0)
    mkDimension (-1) `shouldBe` Left (NonPositiveDimension (-1))
    fmap dimensionValue (mkDimension 1) `shouldBe` Right 1
    fmap dimensionValue (mkDimension (2 ^ (64 :: Int))) `shouldBe` Right (2 ^ (64 :: Int))
  it "admits zero indices and rejects negatives" $ do
    mkWindowIndex (-1) `shouldBe` Left (NegativeIndex (-1))
    mkPaneIndex (-1) `shouldBe` Left (NegativeIndex (-1))
    fmap windowIndexValue (mkWindowIndex 0) `shouldBe` Right 0
    fmap paneIndexValue (mkPaneIndex 0) `shouldBe` Right 0
