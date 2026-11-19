{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module MutationApi where

import Data.Text (Text)
import LibTmux qualified as Tmux
import LibTmux.Server (MutationOptions (timeout), defaultMutationOptions, renameSessionWith)

options :: MutationOptions
options = defaultMutationOptions {timeout = 2}

rename :: Tmux.Server -> Tmux.SessionRef -> Text -> IO ()
rename = renameSessionWith options

renamePhysical :: Tmux.Server -> Tmux.WindowRef -> IO ()
renamePhysical server ref = Tmux.renameWindowWith
  (Tmux.defaultMutationOptions {Tmux.timeout = options.timeout}) server ref "api #{pid};"

title :: Tmux.Server -> Tmux.PaneRef -> IO ()
title server ref = Tmux.setPaneTitle server ref "editor"

paneWidth :: Tmux.Server -> Tmux.PaneRef -> Tmux.Dimension -> IO ()
paneWidth server ref width = Tmux.resizePane server ref (Tmux.ResizeWidth width)

paneSize :: Tmux.Server -> Tmux.PaneRef -> Tmux.Resize -> IO ()
paneSize = Tmux.resizePaneWith options

windowHeight :: Tmux.Server -> Tmux.WindowRef -> Tmux.Dimension -> IO ()
windowHeight server ref height = Tmux.resizeWindow server ref (Tmux.ResizeHeight height)

windowSize :: Tmux.Server -> Tmux.WindowRef -> Tmux.Dimension -> Tmux.Dimension -> IO ()
windowSize server ref width height = Tmux.resizeWindowWith options server ref (Tmux.ResizeBoth width height)
