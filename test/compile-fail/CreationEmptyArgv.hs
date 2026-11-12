{-# LANGUAGE OverloadedStrings #-}

module CreationEmptyArgv where

import LibTmux.Creation (InitialProcess (..))
import System.OsString.Posix qualified as Os

invalid :: InitialProcess
invalid = DirectCommand (Os.fromBytestring "/bin/true") []
