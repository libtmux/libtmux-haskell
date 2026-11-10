module QueryBooleanNumber where

import LibTmux.Query qualified as Q
import LibTmux.Query.Pane qualified as Pane
import LibTmux.Snapshot (Pane)

wrongOperator :: Q.Expr Pane
wrongOperator = Q.ge Pane.active 1
