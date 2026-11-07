{-# LANGUAGE OverloadedStrings #-}

module ValueApi where

import LibTmux.Id
import LibTmux.Value

wideEnough :: Either ValueError Bool
wideEnough = (\width -> dimensionValue width >= 120) <$> mkDimension 120

firstWindow :: Either ValueError WindowIndex
firstWindow = mkWindowIndex 0

firstPane :: Either ValueError PaneIndex
firstPane = mkPaneIndex 0

windowId :: Either IdError WindowId
windowId = parseWindowId "@0"
