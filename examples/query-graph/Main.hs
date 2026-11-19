{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Query one detached graph, then distinguish physical and contextual matches.
module Main (main) where

import Control.Exception (ExceptionWithContext, rethrowIO)
import Data.Bifunctor (first)
import Data.Function ((&))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
import System.Exit (die)

data ApplicationError
  = OperationalFailure (ExceptionWithContext Tmux.TmuxException)
  | InvalidQuery Q.QueryError
  | InvalidSelection Q.CardinalityError
  | UnexpectedResult String

activeWide :: Q.Expr Tmux.Pane
activeWide = Q.allOf [Q.eq F.paneActive True, Q.dimensionAtLeast F.paneWidth 120]

selectedPanes :: Q.Query Tmux.Pane
selectedPanes = Q.panes & Q.matching activeWide

main :: IO ()
main = do
  width <- either (fail . show) pure (Tmux.mkDimension 120)
  alias <- either (fail . show) pure (Tmux.mkWindowIndex 4)
  acquired <- Tmux.tryTmux $ Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    created <- Tmux.createSession server Creation.defaultSessionOptions
      { Creation.width = Just width
      , Creation.process = Creation.ShellCommand "exec /bin/cat -"
      }
    Tmux.linkWindow server (Creation.WindowSlot created.session created.windowIndex)
      (Creation.WindowSlot created.session alias)
    snapshot <- Tmux.capture server
    fresh <- Q.fetch server selectedPanes
    pure (snapshot, fresh)
  case first OperationalFailure acquired >>= uncurry report of
    Left (OperationalFailure problem) -> rethrowIO problem
    Left (InvalidQuery problem) -> die ("Query validation failed: " <> show problem)
    Left (InvalidSelection problem) -> die ("Selection failed: " <> show problem)
    Left (UnexpectedResult problem) -> die problem
    Right linesToPrint -> mapM_ putStrLn linesToPrint

report :: Tmux.Snapshot -> Either Q.QueryError [Tmux.Pane] -> Either ApplicationError [String]
report snapshot acquired = do
  selected <- first InvalidQuery (Q.runQuery snapshot selectedPanes)
  let native = [pane | pane <- Tmux.panes snapshot, pane.active, Tmux.dimensionValue pane.width >= 120]
  if selected == native then Right () else Left (UnexpectedResult "query and native selection disagree")
  unique <- first InvalidSelection (Q.exactlyOne selected)
  occurrences <- first InvalidQuery $ Q.runQuery snapshot $
    Q.paneOccurrences & Q.matching (Q.related F.occurrencePane activeWide)
  highest <- first InvalidQuery $ Q.runQuery snapshot $
    Q.windowLinks & Q.orderBy [Q.descending F.linkIndex] & Q.limit 1
  link <- first InvalidSelection (Q.exactlyOne highest)
  let containingEditors = Q.sessions & Q.matching (Q.some F.sessionWindowLinks (Q.some F.linkPanes activeWide))
  sessions <- first InvalidQuery (Q.runQuery snapshot containingEditors)
  fresh <- first InvalidQuery acquired
  Right
    [ "query agrees with native predicate: True"
    , "unique physical pane: " <> Text.unpack (Tmux.renderPaneId (Tmux.paneId unique.ref))
    , "contextual matches: " <> show (length occurrences)
    , "contextual uniqueness: " <> either show (const "unique") (Q.exactlyOne occurrences)
    , "highest link index: " <> show (Tmux.windowIndexValue link.index)
    , "sessions containing a match: " <> show (length sessions)
    , "required fields: " <> show (Q.requirements selectedPanes).fieldNames
    , "required relationships: " <> show (Q.requirements containingEditors).relationshipNames
    , "fresh capture matches: " <> show (length fresh)
    ]
