module QuerySourceCoercion where

import Data.Coerce (coerce)
import LibTmux.Query (Query)
import LibTmux.Snapshot (Pane, Session)

wrongRow :: Query Pane -> Query Session
wrongRow = coerce
