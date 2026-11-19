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
import Data.Maybe (mapMaybe)
import LibTmux.Version (TmuxVersion, parseVersion)

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

-- | The daemon-dependent requirements read by runtime gates. Program input
-- and screen observation share the program lifetime contract, which requires
-- tmux 3.8 event waits.
capabilityRegistry :: [CapabilityInfo]
capabilityRegistry = map capabilityInfo [minBound .. maxBound]

-- | The authoritative requirement for an operation.
capabilityInfo :: Capability -> CapabilityInfo
capabilityInfo = fst . registryEntry

registryEntry :: Capability -> (CapabilityInfo, Maybe Text)
registryEntry selected = case selected of
  ManagedPrograms -> program "program-execution" ["withProgram", "runProgram", "terminateProgram"] ["new-session", "wait-for -E"]
  ProgramInput -> program "program-input" ["sendProgramInput"] ["send-keys -H", "wait-for -E"]
  RenderedScreen -> program "program-screen" ["readProgramScreen"] ["capture-pane", "save-buffer", "wait-for -E"]
  ProgramExitEvents -> program "program-exit" ["waitProgram", "waitProgramFor"] ["wait-for -E", "pane-died", "window-unlinked", "window-layout-changed"]
  RawBufferPasteFlag -> entry "paste-buffer-no-vis" "3.7" Fallback ["pasteBuffer", "pasteBufferWith"] ["paste-buffer -S"]
  where
    program key = entry key "3.8" Refuse
    entry key minimumRelease policy publicApis nativeCommands =
      (CapabilityInfo selected key (either (error . show) id (parseVersion minimumRelease)) policy publicApis nativeCommands, Nothing)

-- | Whether this complete operation is available. This is a version check;
-- host process-group support and endpoint liveness are checked separately.
supports :: Capabilities -> Capability -> Bool
supports available selected = daemonVersion available >= (capabilityInfo selected).since

-- | Refuse an unavailable operation without performing external effects.
requireCapability :: Capabilities -> Capability -> Either CapabilityError ()
requireCapability available selected
  | supports available selected = Right ()
  | otherwise = Left (CapabilityUnavailable selected (daemonVersion available))

-- | The shared @libtmux-capabilities/1@ projection of the runtime registry.
-- Its vocabulary currently names none of this port's gated operations, so
-- both claim arrays are empty. 'capabilityRegistry' still reports every
-- Haskell operation and 'supports' checks the connected daemon's release.
-- The unit suite checks the packaged @capabilities.json@ against this value.
capabilityManifest :: Text
capabilityManifest = "{\n  \"schema\": \"libtmux-capabilities/1\",\n  \"port\": \"haskell\",\n"
  <> "  \"floor\": {\"minimum\": \"3.3a\"},\n  \"capabilities\": ["
  <> Text.intercalate ", " shared <> "],\n  \"workarounds\": []\n}\n"
  where
    shared = mapMaybe (snd . registryEntry . (.capability)) capabilityRegistry
