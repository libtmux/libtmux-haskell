{-# LANGUAGE OverloadedStrings #-}

module MutationWrongEntity where

import LibTmux (Server, PaneRef, renameWindow)

invalid :: Server -> PaneRef -> IO ()
invalid server pane = renameWindow server pane "wrong entity"
