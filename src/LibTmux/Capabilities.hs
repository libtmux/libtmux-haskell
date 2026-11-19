-- | Discover daemon-dependent application operations before creating resources.
-- The table describes the complete Haskell operation, including its required
-- exit observation. The general library admission floor remains separate.
module LibTmux.Capabilities
  ( Capability (..), CapabilityInfo (..), CapabilityHandling (..)
  , Capabilities, CapabilityError (..)
  , capabilitiesFor, daemonVersion, capabilityInfo, capabilityRegistry
  , supports, requireCapability, capabilityManifest
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux.Version (TmuxVersion, parseVersion, renderVersion)

-- | Individually discoverable daemon operations and command flags.
data Capability
  = ManagedPrograms | ProgramInput | RenderedScreen | ProgramExitEvents | RawBufferPasteFlag
  deriving stock (Eq, Ord, Enum, Bounded, Show)

-- | Refuse the operation or use an older native behavior below its floor.
data CapabilityHandling = Refuse | Fallback
  deriving stock (Eq, Show)

-- | One canonical feature requirement and its behavior below 'since'.
data CapabilityInfo = CapabilityInfo
  { capability :: !Capability
  , identifier :: !Text
  , since :: !TmuxVersion
  , handling :: !CapabilityHandling
  , apis :: ![Text]
  , commands :: ![Text]
  }
  deriving stock (Eq, Show)

-- | A release supplied by the caller, or observed from the pinned daemon by
-- 'LibTmux.Server.serverCapabilities'. A client executable's release is irrelevant.
newtype Capabilities = Capabilities TmuxVersion
  deriving stock (Eq, Show)

-- | An unavailable operation and the actual daemon release.
data CapabilityError = CapabilityUnavailable !Capability !TmuxVersion
  deriving stock (Eq, Show)
instance Exception CapabilityError

-- | Evaluate the registry against a supplied version without external effects.
capabilitiesFor :: TmuxVersion -> Capabilities
capabilitiesFor = Capabilities

-- | The release against which these capabilities were evaluated.
daemonVersion :: Capabilities -> TmuxVersion
daemonVersion (Capabilities version) = version

-- | Every application operation depends on tmux 3.8 event waits. Input and
-- screen observation share that lifetime contract even though their underlying
-- tmux commands predate 3.8. Each API uses this table for admission.
capabilityRegistry :: [CapabilityInfo]
capabilityRegistry = map capabilityInfo [minBound .. maxBound]

-- | The authoritative requirement for an operation.
capabilityInfo :: Capability -> CapabilityInfo
capabilityInfo selected = case selected of
  ManagedPrograms -> program "program-execution" ["withProgram", "runProgram", "terminateProgram"] ["new-session", "wait-for -E"]
  ProgramInput -> program "program-input" ["sendProgramInput"] ["send-keys -H", "wait-for -E"]
  RenderedScreen -> program "program-screen" ["readProgramScreen"] ["capture-pane", "save-buffer", "wait-for -E"]
  ProgramExitEvents -> program "program-exit" ["waitProgram", "waitProgramFor"] ["wait-for -E", "pane-died", "window-unlinked", "window-layout-changed"]
  RawBufferPasteFlag -> entry "paste-buffer-no-vis" "3.7" Fallback ["pasteBuffer", "pasteBufferWith"] ["paste-buffer -S"]
  where
    program key = entry key "3.8" Refuse
    entry key minimumRelease = CapabilityInfo selected key (either (error . show) id (parseVersion minimumRelease))

-- | Whether this complete operation is available. This is a version check;
-- host process-group support and endpoint liveness are checked separately.
supports :: Capabilities -> Capability -> Bool
supports available selected = daemonVersion available >= (capabilityInfo selected).since

-- | Refuse an unavailable operation without performing external effects.
requireCapability :: Capabilities -> Capability -> Either CapabilityError ()
requireCapability available selected
  | supports available selected = Right ()
  | otherwise = Left (CapabilityUnavailable selected (daemonVersion available))

-- | Deterministic metadata generated from the same table as the runtime gates.
-- The unit suite checks the packaged @capabilities.json@ against this value.
capabilityManifest :: Text
capabilityManifest = "{\n  \"schema\": \"libtmux-capabilities/1\",\n  \"capabilities\": [\n"
  <> Text.intercalate ",\n" (map entry capabilityRegistry) <> "\n  ]\n}\n"
  where
    quote value = "\"" <> value <> "\""
    array values = "[" <> Text.intercalate ", " (map quote values) <> "]"
    entry info = "    {\"id\": " <> quote info.identifier
      <> ", \"since\": " <> quote (renderVersion info.since)
      <> ", \"handling\": " <> quote (case info.handling of Refuse -> "refuse"; Fallback -> "fallback")
      <> ", \"apis\": " <> array info.apis
      <> ", \"commands\": " <> array info.commands <> "}"
