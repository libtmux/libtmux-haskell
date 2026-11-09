{-# LANGUAGE OverloadedStrings #-}
module QueryWrongOperand where

import Data.Text (Text)
import LibTmux.Query qualified as Q
import LibTmux.Query.Pane qualified as Pane
import LibTmux.Snapshot (Pane)

wrongOperand :: Q.Expr Pane
wrongOperand = Q.eq Pane.active ("yes" :: Text)
