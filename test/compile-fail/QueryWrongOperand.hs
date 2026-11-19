{-# LANGUAGE OverloadedStrings #-}
module QueryWrongOperand where

import Data.Text (Text)
import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
import LibTmux.Snapshot (Pane)

wrongOperand :: Q.Expr Pane
wrongOperand = Q.eq F.paneActive ("yes" :: Text)
