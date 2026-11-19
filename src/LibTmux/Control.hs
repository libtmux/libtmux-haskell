-- | Observe tmux control notifications from 'LibTmux.Server.withControl'.
-- Read from the bounded queue in STM. The enclosing Server retains ownership
-- of the daemon.
module LibTmux.Control
  ( Control
  , ControlOptions (..), defaultControlOptions
  , ControlEvent (..), ControlEnd (..), ControlError (..)
  , readControlEvent, pollControlEvent
  ) where

import LibTmux.Internal.Control
