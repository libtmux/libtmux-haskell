-- | Private file transfers separate binary buffer data from native replies.
module LibTmux.Internal.Buffer (byteLimit, withInput, readOutput) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (allowInterrupt, bracket, bracket_, evaluate, finally)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import GHC.Conc (threadWaitRead)
import LibTmux.Internal.Process (inputLimitBytes)
import LibTmux.Internal.Process.Native qualified as Native
import System.IO (hClose, hFlush)
import System.Posix.Directory.ByteString (removeDirectory)
import System.Posix.Files.ByteString (createNamedPipe, removeLink)
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Temp.ByteString (mkdtemp, mkstemp)
import System.Posix.Types (Fd (..))

byteLimit :: Int
byteLimit = inputLimitBytes

-- | Supply a fully written, owner-only file until the native request returns.
withInput :: ByteString -> (ByteString -> IO a) -> IO a
withInput bytes action = withDirectory $ \directory ->
  bracket (mkstemp (directory <> "/input-")) retire $ \(file, output) -> do
    Bytes.hPut output bytes
    hFlush output
    action file
  where
    retire (file, output) = hClose output `finally` removeLink file

-- | Keep only bounded data while the native file callback completes. A private
-- writer prevents premature EOF before the tmux client opens its own writer.
-- Both native callbacks and hooks can run without contaminating these bytes.
readOutput :: (ByteString -> IO ()) -> IO (Maybe ByteString)
readOutput action = withDirectory $ \directory -> do
  let pipe = directory <> "/output"
      flags = Posix.defaultFileFlags {Posix.nonBlock = True, Posix.cloexec = True}
      withDescriptor :: Posix.OpenMode -> (Fd -> IO a) -> IO a
      withDescriptor mode = bracket (Posix.openFd pipe mode flags) Posix.closeFd
  bracket_ (createNamedPipe pipe 0o600) (removeLink pipe) $
    withDescriptor Posix.ReadOnly $ \input -> do
      started <- newEmptyMVar
      withAsync (takeMVar started >> receive input) $ \reader -> do
        withDescriptor Posix.WriteOnly $ \_ -> do
          putMVar started ()
          action pipe
        wait reader

withDirectory :: (ByteString -> IO a) -> IO a
withDirectory = bracket (mkdtemp "/tmp/libtmux-haskell-buffer-") removeDirectory

receive :: Fd -> IO (Maybe ByteString)
receive descriptor@(Fd input) = loop 0 []
  where
    loop !size chunks = do
      allowInterrupt
      Native.readChunk input >>= \case
        Nothing -> threadWaitRead descriptor >> loop size chunks
        Just bytes
          | Bytes.null bytes && size > byteLimit -> pure Nothing
          | Bytes.null bytes -> Just <$> evaluate (Bytes.concat (reverse chunks))
          | size + Bytes.length bytes > byteLimit -> loop (byteLimit + 1) []
          | otherwise -> loop (size + Bytes.length bytes) (bytes : chunks)
