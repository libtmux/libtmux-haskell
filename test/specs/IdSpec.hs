module IdSpec (spec) where

import Data.Either (isLeft)
import Data.Text qualified as Text
import IdProperties (propPaneIdRoundTrip)
import LibTmux.Id
import Test.Hspec

spec :: Spec
spec = describe "typed tmux IDs" $ do
  it "round-trips zero and the native unsigned upper bound" $ do
    fmap renderSessionId (parseSessionId "$0") `shouldBe` Right "$0"
    fmap renderWindowId (parseWindowId "@42") `shouldBe` Right "@42"
    fmap renderPaneId (parsePaneId "%4294967295") `shouldBe` Right "%4294967295"
    fmap paneIdValue (parsePaneId "%4294967295") `shouldBe` Right 4294967295
  it "rejects wrong entities, overflow and noncanonical external data" $ do
    parseSessionId "@1" `shouldSatisfy` isLeft
    parseWindowId "%1" `shouldSatisfy` isLeft
    mapM_ (\input -> parsePaneId input `shouldSatisfy` isLeft)
      ["%", "%4294967296", "%01", "%-1", "%1\n", "%1x", "%١", " %1"]
    let huge = Text.replicate 1000 "1"
    parsePaneId huge `shouldBe` Left (InvalidId '%' (Text.take 64 huge))
  it "preserves numeric meaning and canonical spelling across the native domain" propPaneIdRoundTrip
