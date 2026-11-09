module QueryExprCoercion where

import Data.Coerce (coerce)
import LibTmux.Query (Expr)
import LibTmux.Snapshot (Pane, Session)

wrongRow :: Expr Pane -> Expr Session
wrongRow = coerce
