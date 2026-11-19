-- | Discover options and hooks from tmux's released option tables.
-- Use 'LibTmux.Server.serverCapabilities' for the connected daemon.
module LibTmux.Options
  ( OptionScope (..), OptionKind (..), OptionShape (..)
  , OptionInfo (..), HookInfo (..)
  , knownOptions, lookupOption, knownHooks, lookupHook
  ) where

import Data.Bifunctor (first)
import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import LibTmux.Capabilities (Capabilities, daemonVersion)
import LibTmux.Internal.OptionTable
  ( Definition (..), OptionScope (..), OptionKind (..), OptionShape (..), definitions )
import LibTmux.Version (TmuxVersion, parseVersion)

-- | The definition in the selected release. 'optionSince' is the first
-- qualified release of the current availability period.
data OptionInfo = OptionInfo
  { optionName :: !Text
  , optionKind :: !OptionKind
  , optionScopes :: ![OptionScope]
  , optionShape :: !OptionShape
  , optionChoices :: ![Text]
  , optionSince :: !TmuxVersion
  }
  deriving stock (Eq, Show)

-- | An event with native command-array storage and its permitted scopes.
data HookInfo = HookInfo
  { hookName :: !Text
  , hookScopes :: ![OptionScope]
  , hookSince :: !TmuxVersion
  }
  deriving stock (Eq, Show)

-- | List built-in options by name. The catalogue uses the latest pinned
-- release at or below the daemon's version, from 3.3a through 3.8.
knownOptions :: Capabilities -> [OptionInfo]
knownOptions capabilities =
  mapMaybe (lookupOption capabilities) (Map.keys catalogue)

-- | Look up a canonical built-in option name in the selected catalogue.
lookupOption :: Capabilities -> Text -> Maybe OptionInfo
lookupOption capabilities name = case definitionAt capabilities name of
  Just (since, Option kind scopes shape choices) ->
    Just (OptionInfo name kind scopes shape choices since)
  _ -> Nothing

-- | List the known hooks by event name, with the same version selection as
-- 'knownOptions'.
knownHooks :: Capabilities -> [HookInfo]
knownHooks capabilities = mapMaybe (lookupHook capabilities) (Map.keys catalogue)

-- | Look up the event's canonical name. Removed or unknown hooks are absent.
lookupHook :: Capabilities -> Text -> Maybe HookInfo
lookupHook capabilities name = case definitionAt capabilities name of
  Just (since, Hook scopes) -> Just (HookInfo name scopes since)
  _ -> Nothing

type History = [(TmuxVersion, Maybe (TmuxVersion, Definition))]

catalogue :: Map Text History
catalogue = Map.fromList
  [(name, map versioned history) | (name, history) <- definitions]
  where
    versioned (release, entry) = (version release, first version <$> entry)
    version = either (error . show) id . parseVersion

definitionAt :: Capabilities -> Text -> Maybe (TmuxVersion, Definition)
definitionAt capabilities name = do
  history <- Map.lookup name catalogue
  let released = takeWhile ((<= daemonVersion capabilities) . fst) history
  foldl' (\_ (_, definition) -> definition) Nothing released
