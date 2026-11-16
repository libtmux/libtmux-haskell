{-# LANGUAGE OverloadedStrings #-}

module OwnedServerPinDirectory where

import LibTmux qualified as Tmux
import System.OsString.Posix qualified as Os

config :: Tmux.OwnedServerConfig
config = Tmux.defaultOwnedServerConfig {Tmux.pinDirectory = Os.fromBytestring "/tmp"}
