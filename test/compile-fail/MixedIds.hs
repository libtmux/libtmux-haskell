module MixedIds where

import LibTmux.Id (PaneId, WindowId)

invalid :: PaneId -> WindowId
invalid = id
