-- | Typed selection over detached tmux observations.
--
-- Build a t'Query' with a source and 'matching', then use 'runQuery' to read
-- an existing t'Snapshot' without IO. 'fetch' explicitly acquires a new
-- snapshot. Ordinary lists and application predicates remain available
-- through "LibTmux.Snapshot"; portable expressions contain no callbacks.
--
-- Import field modules qualified: "LibTmux.Query.Pane",
-- "LibTmux.Query.Session", "LibTmux.Query.Window", "LibTmux.Query.Link",
-- "LibTmux.Query.Occurrence", "LibTmux.Query.Client",
-- "LibTmux.Query.ClientAttachment" and "LibTmux.Query.ServerInfo".
-- Field tokens describe captured values; reading them never contacts tmux.
--
-- Query construction, operands and results are finite. Execution validates
-- every declared requirement before filtering, stably ordering and limiting.
-- The default source order and multiplicity come from the supplied snapshot.
-- A result establishes what was observed, not current liveness or a reserved
-- command target. See 'exactlyOne' before selecting an explicit reference.
--
-- >>> exactlyOne [1 :: Integer]
-- Right 1
-- >>> exactlyOne ([] :: [Integer])
-- Left NoMatches
-- >>> atMostOne ([] :: [Integer])
-- Right Nothing
-- >>> atMostOne [1, 2 :: Integer]
-- Left AtLeastTwoMatches
--
module LibTmux.Query
  ( -- * Descriptions
    Field, Expr, Query, Order, ToMany, ToOne, ToOptional
    -- * Ordered sources
  , sessions, windows, panes, windowLinks, paneOccurrences, clients, serverInfo
    -- * Scalar predicates
  , eq, oneOf, contains, ge, gt, le, lt
  , dimensionAtLeast, dimensionAtMost, paneIndexAtLeast, paneIndexAtMost
  , windowIndexAtLeast, windowIndexAtMost
    -- * Logic and relationships
  , allOf, anyOf, not_, some, every, none, related, optionalRelated
    -- * Selection and ordering
  , matching, orderBy, ascending, descending, limit
    -- * Inspect and evaluate
  , QueryRequirements (..), requirements, QueryError (..), runQuery, fetch
    -- * Cardinality
  , CardinalityError (..), exactlyOne, atMostOne
  ) where

import LibTmux.Internal.Field (Field)
import LibTmux.Internal.Query
  ( Expr, Query, Order, ToMany, ToOne, ToOptional
  , sessions, windows, panes, windowLinks, paneOccurrences, clients, serverInfo
  , eq, oneOf, contains, ge, gt, le, lt
  , dimensionAtLeast, dimensionAtMost, paneIndexAtLeast, paneIndexAtMost
  , windowIndexAtLeast, windowIndexAtMost
  , allOf, anyOf, not_, some, every, none, related, optionalRelated
  , matching, orderBy, ascending, descending, limit
  , QueryRequirements (..), requirements, QueryError (..)
  , CardinalityError (..), exactlyOne, atMostOne
  )
import LibTmux.Internal.Query qualified as Q
import LibTmux.Server (Server)
import LibTmux.Server qualified as Server
import LibTmux.Snapshot (Snapshot)

-- | Validate and evaluate against the supplied complete snapshot. Every
-- requirement is checked before reading rows, including empty sources and
-- zero limits. Consuming a successful result performs only pure processing
-- of owned observations. No acquisition, pushdown or refresh occurs.
runQuery :: Snapshot -> Query row -> Either QueryError [row]
runQuery = Q.runQuery

-- | Acquire a complete fresh snapshot and evaluate the query against it.
-- Compiled evaluator support is checked before IO; version requirements are
-- checked against acquired server metadata. Operational failures propagate
-- as exceptions from 'LibTmux.Server.capture'; use 'LibTmux.Server.tryTmux' to retain their
-- context and recovery owners. Cancellation propagates unchanged.
--
-- This performs one acquisition per call, even when the query is reused or
-- has a zero limit. Use 'runQuery' to reuse an existing t'Snapshot'. No filter
-- is pushed into tmux in this implementation.
fetch :: Server -> Query row -> IO (Either QueryError [row])
fetch server query = case Q.prepare Q.nativeProfile query of
  Left problem -> pure (Left problem)
  Right () -> (`runQuery` query) <$> Server.capture server
