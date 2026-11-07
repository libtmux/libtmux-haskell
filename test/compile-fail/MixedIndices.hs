module MixedIndices where

import LibTmux.Value (PaneIndex, WindowIndex)

invalid :: PaneIndex -> WindowIndex
invalid = id
