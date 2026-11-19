module RecoveryFromUmbrella where

import LibTmux qualified as Tmux

available :: Bool
available = Tmux.inspectCleanup `seq` True
