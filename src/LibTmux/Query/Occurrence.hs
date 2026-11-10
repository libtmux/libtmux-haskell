-- | Context-preserving pane appearances for "LibTmux.Query".
--
-- These tmux 3.3a baseline relationships read detached t'PaneOccurrence'
-- values. Filtering occurrences preserves repeated appearances; use the
-- physical pane source when uniqueness should ignore links.
module LibTmux.Query.Occurrence (pane, link) where

import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (ToOne)
import LibTmux.Snapshot (PaneOccurrence, Pane, WindowLink)

-- | The physical pane observed through this occurrence, used with 'LibTmux.Query.related'.
pane :: ToOne PaneOccurrence Pane
pane = Q.OccurrencePane

-- | The observed session and window-index context of this appearance.
link :: ToOne PaneOccurrence WindowLink
link = Q.OccurrenceLink
