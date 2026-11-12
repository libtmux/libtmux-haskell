-- | Observe the daemon version without running command hooks or a shell.
-- A nonce-qualified non-command is expanded by @run-shell -C@ and returned
-- in its parse error. Success or any unrelated diagnostic supplies no evidence.
module LibTmux.Internal.VersionProbe
  ( ProbeError (..), versionArguments, decodeVersionProbe ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Text.Encoding qualified as Utf8
import LibTmux.Internal.Frame qualified as F
import LibTmux.Version qualified as V

data ProbeError
  = UnexpectedProbeReply | InvalidProbeFrame !F.FrameError
  | InvalidProbeEncoding | InvalidProbeVersion !V.VersionError
  deriving stock (Eq, Show)

versionArguments :: F.Nonce -> [ByteString]
versionArguments nonce = ["run-shell", "-C", F.scalarFormat nonce "#{version}"]

decodeVersionProbe :: F.Nonce -> Maybe Int -> ByteString -> ByteString -> Either ProbeError V.TmuxVersion
decodeVersionProbe nonce status output diagnostic
  | status /= Just 1 || not (Bytes.null output) || Bytes.length diagnostic > 512 = Left UnexpectedProbeReply
  | otherwise = do
      framed <- maybe (Left UnexpectedProbeReply) Right (Bytes.stripPrefix "unknown command: " diagnostic)
      payload <- either (Left . InvalidProbeFrame) Right (F.decodeScalar nonce 64 framed)
      text <- either (const (Left InvalidProbeEncoding)) Right (Utf8.decodeUtf8' payload)
      version <- either (Left . InvalidProbeVersion) Right (V.parseVersion text)
      if Utf8.encodeUtf8 (V.renderVersion version) == payload
        then Right version
        else Left UnexpectedProbeReply
