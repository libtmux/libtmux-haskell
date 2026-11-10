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
