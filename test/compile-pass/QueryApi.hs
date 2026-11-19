{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module QueryApi where

import Data.Function ((&))
import LibTmux qualified as Tmux
import LibTmux.Query (Expr, Query)
import LibTmux.Query qualified as Q
import LibTmux.Query.Client qualified as Client
import LibTmux.Query.ClientAttachment qualified as Attachment
import LibTmux.Query.Link qualified as Link
import LibTmux.Query.Occurrence qualified as Occurrence
import LibTmux.Query.Pane qualified as Pane
import LibTmux.Query.ServerInfo qualified as ServerInfo
import LibTmux.Query.Session qualified as Session
import LibTmux.Query.Window qualified as Window

editors :: Expr Tmux.Pane
editors = Q.allOf [Q.eq Pane.active True, Q.dimensionAtLeast Pane.width 120]

selected :: Query Tmux.Pane
selected = Q.panes & Q.matching editors & Q.orderBy [Q.ascending Pane.id] & Q.limit 2

sameLabel :: Tmux.Window -> Query Tmux.Window
sameLabel window = Q.windows & Q.matching (Q.eq Window.name window.name)

clientSelection :: Query Tmux.Client
clientSelection = Q.clients & Q.matching
  (Q.optionalRelated Client.attachment (Q.related Attachment.pane (Q.related Occurrence.pane editors)))

containing :: Query Tmux.Session
containing = Q.sessions & Q.matching (Q.some Session.windowLinks (Q.some Link.panes editors))

metadata :: Query Tmux.ServerInfo
metadata = Q.serverInfo & Q.matching (Q.ge ServerInfo.pid 1)

operational :: Tmux.Server -> IO (Either Q.QueryError [Tmux.Pane])
operational = flip Q.fetch selected

local :: Tmux.Snapshot -> Either Q.QueryError [Tmux.Pane]
local = flip Q.runQuery selected

grouped :: Query Tmux.Session
grouped = Q.sessions & Q.matching (Q.eq Session.group (Just "team"))

zoomedLayout :: Query Tmux.Window
zoomedLayout = Q.windows & Q.matching (Q.allOf [Q.eq Window.zoomed True, Q.contains Window.layout "layout"])

flagged :: Query Tmux.WindowLink
flagged = Q.windowLinks & Q.matching (Q.contains Link.flags "Z")

modeCursor :: Query Tmux.Pane
modeCursor = Q.panes & Q.matching (Q.allOf [Q.ge Pane.cursorX 0, Q.ge Pane.cursorY 0,
  Q.ge Pane.modeCount 1, Q.eq Pane.mode (Just "copy-mode")])

sized :: Query Tmux.Client
sized = Q.clients & Q.matching (Q.allOf [Q.ge Client.width 80, Q.eq Client.height Nothing])
