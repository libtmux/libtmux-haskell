module CreationEmptyPane where

import LibTmux.Creation qualified as Creation

invalid :: Creation.InitialProcess
invalid = Creation.EmptyPane
