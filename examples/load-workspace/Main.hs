{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Bytes
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Workspace qualified as Workspace
import System.Directory (getCurrentDirectory)

main :: IO ()
main = do
  directory <- getCurrentDirectory
  plan <- require
    (Workspace.planTmuxp (Workspace.defaultPlanInputs directory) document)
  let preview = Workspace.previewWorkspace plan
  putStrLn ("session: " <> Text.unpack preview.sessionName)
  putStrLn ("planned windows: " <> show (NonEmpty.length preview.windows))
  Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    session <- Workspace.applyWorkspace server plan
    snapshot <- Tmux.capture server
    links <- require (Tmux.linksForSession snapshot session)
    panes <- traverse (require . Tmux.panesForWindow snapshot . (.window)) links
    putStrLn ("applied panes: " <> show (sum (map length panes)))

document :: ByteString
document = Bytes.unlines
  [ "session_name: review"
  , "windows:"
  , "  - window_name: editor"
  , "    layout: even-horizontal"
  , "    panes: [blank, blank]"
  , "  - window_name: tests"
  ]

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
