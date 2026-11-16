-- | Observe daemon scalars without running command hooks or a shell.
-- A nonce-qualified non-command is expanded by @run-shell -C@ and returned
-- in its parse error. Success or any unrelated diagnostic supplies no evidence.
-- The release and the daemon's process ID share this channel.
module LibTmux.Internal.VersionProbe
  ( ProbeError (..), versionArguments, pidArguments, decodeVersionProbe, decodePidProbe, parseServerPid ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Text.Encoding qualified as Utf8
import Foreign.C.Types (CInt)
import LibTmux.Internal.Frame qualified as F
import LibTmux.Version qualified as V

data ProbeError
  = UnexpectedProbeReply | InvalidProbeFrame !F.FrameError
  | InvalidProbeEncoding | InvalidProbeVersion !V.VersionError | InvalidProbePid
  deriving stock (Eq, Show)

versionArguments :: F.Nonce -> [ByteString]
versionArguments nonce = probeArguments nonce "#{version}"

pidArguments :: F.Nonce -> [ByteString]
pidArguments nonce = probeArguments nonce "#{pid}"

probeArguments :: F.Nonce -> ByteString -> [ByteString]
probeArguments nonce format = ["run-shell", "-C", F.scalarFormat nonce format]

-- | The bounded payload of the daemon's parse error, or no evidence.
decodeProbe :: F.Nonce -> Int -> Maybe Int -> ByteString -> ByteString -> Either ProbeError ByteString
decodeProbe nonce bound status output diagnostic
  | status /= Just 1 || not (Bytes.null output) || Bytes.length diagnostic > 512 = Left UnexpectedProbeReply
  | otherwise = do
      framed <- maybe (Left UnexpectedProbeReply) Right (Bytes.stripPrefix "unknown command: " diagnostic)
      either (Left . InvalidProbeFrame) Right (F.decodeScalar nonce bound framed)

decodeVersionProbe :: F.Nonce -> Maybe Int -> ByteString -> ByteString -> Either ProbeError V.TmuxVersion
decodeVersionProbe nonce status output diagnostic = do
  payload <- decodeProbe nonce 64 status output diagnostic
  text <- either (const (Left InvalidProbeEncoding)) Right (Utf8.decodeUtf8' payload)
  version <- either (Left . InvalidProbeVersion) Right (V.parseVersion text)
  if Utf8.encodeUtf8 (V.renderVersion version) == payload
    then Right version
    else Left UnexpectedProbeReply

decodePidProbe :: F.Nonce -> Maybe Int -> ByteString -> ByteString -> Either ProbeError Integer
decodePidProbe nonce status output diagnostic = do
  payload <- decodeProbe nonce 32 status output diagnostic
  maybe (Left InvalidProbePid) Right (parseServerPid payload)

-- | A positive decimal process ID that fits a C @int@, without a sign.
parseServerPid :: ByteString -> Maybe Integer
parseServerPid bytes = case Ascii.readInteger bytes of
  Just (pid, "") | Bytes.length bytes <= 10 && Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes
      && pid > 0 && pid <= toInteger (maxBound @CInt) -> Just pid
  _ -> Nothing
