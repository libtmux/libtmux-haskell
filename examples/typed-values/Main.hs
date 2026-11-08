{-# LANGUAGE OverloadedStrings #-}

-- | Construct tmux domain values without starting a process
-- or contacting a server.
module Main (main) where

import LibTmux.Id (parseWindowId, renderWindowId)
import LibTmux.Value (dimensionValue, mkDimension)
import LibTmux.Version (parseVersion, renderVersion, requireSupported)

main :: IO ()
main = do
  version <- either (fail . show) pure $
    parseVersion "tmux 3.3\n" >>= requireSupported
  window <- either (fail . show) pure (parseWindowId "@17")
  width <- either (fail . show) pure (mkDimension 120)
  print (renderVersion version, renderWindowId window, dimensionValue width)
