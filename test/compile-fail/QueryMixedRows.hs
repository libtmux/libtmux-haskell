module QueryMixedRows where

import LibTmux.Query qualified as Q
import LibTmux.Query.Session qualified as Session
import LibTmux.Snapshot (Pane)

wrongRow :: Q.Query Pane
wrongRow = Q.matching (Q.ge Session.attached 1) Q.panes
