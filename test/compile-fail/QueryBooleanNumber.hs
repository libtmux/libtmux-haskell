module QueryBooleanNumber where

import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
import LibTmux.Snapshot (Pane)

wrongOperator :: Q.Expr Pane
wrongOperator = Q.ge F.paneActive 1
