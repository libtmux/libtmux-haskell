module IdProperties (propPaneIdRoundTrip) where

import Data.Text qualified as Text
import LibTmux.Id
import Test.QuickCheck

nativeMaximum :: Integer
nativeMaximum = 4294967295

propPaneIdRoundTrip :: Property
propPaneIdRoundTrip = checkCoverage $
  forAllShrink generator (filter (\n -> n >= 0 && n <= nativeMaximum) . shrink) $ \value ->
    let encoded = "%" <> Text.pack (show value)
    in cover 5 (value == 0) "zero" $
       cover 5 (value == nativeMaximum) "native maximum" $
       fmap (\pane -> (paneIdValue pane, renderPaneId pane)) (parsePaneId encoded)
         === Right (value, encoded)
  where
    generator = frequency
      [(2, pure 0), (2, pure nativeMaximum), (6, chooseInteger (1, nativeMaximum - 1))]
