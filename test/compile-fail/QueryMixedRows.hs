module QueryMixedRows where

import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
import LibTmux.Snapshot (Pane)

wrongRow :: Q.Query Pane
wrongRow = Q.matching (Q.ge F.sessionAttached 1) Q.panes
