{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module ObservationApi where

import Data.Text (Text)
import LibTmux qualified as Tmux
import LibTmux.Snapshot (Pane (width), Session (name))
import LibTmux.Snapshot qualified as Session (Session (..))

qualifiedName :: Tmux.Session -> Text
qualifiedName session = session.name

selectiveName :: Session -> Text
selectiveName session = session.name

localUpdate :: Session.Session -> Session.Session
localUpdate session = session {Session.name = "local observation"}

projectWidths :: [Pane] -> [Tmux.Dimension]
projectWidths = map (.width)

useful :: Tmux.Pane -> Bool
useful pane = pane.active && Tmux.dimensionValue pane.width >= 120

sessionFields :: Session.Session -> (Tmux.SessionRef, Text, Integer)
sessionFields Session.Session {Session.ref = ident, Session.name = label, Session.attached = count} =
  (ident, label, count)
