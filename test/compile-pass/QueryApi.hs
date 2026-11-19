{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module QueryApi where

import Data.Function ((&))
import LibTmux qualified as Tmux
import LibTmux.Query (Expr, Query)
import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F

editors :: Expr Tmux.Pane
editors = Q.allOf [Q.eq F.paneActive True, Q.dimensionAtLeast F.paneWidth 120]

selected :: Query Tmux.Pane
selected = Q.panes & Q.matching editors & Q.orderBy [Q.ascending F.paneId] & Q.limit 2

sameLabel :: Tmux.Window -> Query Tmux.Window
sameLabel window = Q.windows & Q.matching (Q.eq F.windowName window.name)

clientSelection :: Query Tmux.Client
clientSelection = Q.clients & Q.matching
  (Q.optionalRelated F.clientAttachment (Q.related F.clientAttachmentPane (Q.related F.occurrencePane editors)))

containing :: Query Tmux.Session
containing = Q.sessions & Q.matching (Q.some F.sessionWindowLinks (Q.some F.linkPanes editors))

metadata :: Query Tmux.ServerInfo
metadata = Q.serverInfo & Q.matching (Q.ge F.serverInfoPid 1)

operational :: Tmux.Server -> IO (Either Q.QueryError [Tmux.Pane])
operational = flip Q.fetch selected

local :: Tmux.Snapshot -> Either Q.QueryError [Tmux.Pane]
local = flip Q.runQuery selected

grouped :: Query Tmux.Session
grouped = Q.sessions & Q.matching (Q.eq F.sessionGroup (Just "team"))

zoomedLayout :: Query Tmux.Window
zoomedLayout = Q.windows & Q.matching (Q.allOf [Q.eq F.windowZoomed True, Q.contains F.windowLayout "layout"])

flagged :: Query Tmux.WindowLink
flagged = Q.windowLinks & Q.matching (Q.contains F.linkFlags "Z")

modeCursor :: Query Tmux.Pane
modeCursor = Q.panes & Q.matching (Q.allOf [Q.ge F.paneCursorX 0, Q.ge F.paneCursorY 0,
  Q.ge F.paneModeCount 1, Q.eq F.paneMode (Just "copy-mode")])

sized :: Query Tmux.Client
sized = Q.clients & Q.matching (Q.allOf [Q.ge F.clientWidth 80, Q.eq F.clientHeight Nothing])
