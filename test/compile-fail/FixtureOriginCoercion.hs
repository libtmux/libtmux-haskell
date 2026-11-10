module FixtureOriginCoercion where

import Data.Coerce (coerce)
import LibTmux.Snapshot (Generation)
import LibTmux.Snapshot.Fixture (FixtureOrigin)

forgeOrigin :: Generation -> FixtureOrigin
forgeOrigin = coerce
