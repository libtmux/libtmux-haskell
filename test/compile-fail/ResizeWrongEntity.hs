module ResizeWrongEntity where

import LibTmux (Dimension, PaneRef, Resize (ResizeWidth), Server, resizeWindow)

invalid :: Server -> PaneRef -> Dimension -> IO ()
invalid server pane width = resizeWindow server pane (ResizeWidth width)
