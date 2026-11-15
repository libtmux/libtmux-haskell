module CreationConstructor where

import LibTmux.Creation qualified as Creation

invalid :: Creation.CreatedSession
invalid = Creation.CreatedSession undefined undefined undefined undefined undefined
