{-# LANGUAGE ForeignFunctionInterface #-}
module GuardianWitness where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (forever, unless, when)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import Foreign.Marshal.Array (allocaArray, peekArray)
import GHC.Conc (getNumCapabilities, threadWaitRead)
import System.Posix.Types (Fd (..))
import LibTmux.Internal.Process.Native qualified as N
import System.Directory qualified as Directory
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Posix.Temp (mkdtemp)
import System.Process.Typed

foreign import ccall safe "libtmux_test_guardian_fixture_subreaper" cSubreaper :: IO CInt
foreign import ccall safe "libtmux_test_guardian_witness_server" cServer :: CString -> IO CInt
foreign import ccall safe "libtmux_test_guardian_witness_take" cTake :: CInt -> Ptr CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_fixture_retire" cRetire :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_test_guardian_witness_pending" cPending :: CInt -> IO CInt

checked :: CInt -> IO ()
checked rc = when (rc<0) (N.raise (negate rc))

withLauncher :: Int -> Bytes.ByteString -> (Bytes.ByteString -> CInt -> IO a) -> IO a
withLauncher mode tmux action = bracket (mkdtemp "/tmp/libtmux-guardian-case-") Directory.removePathForcibly $ \directory -> do
  let socket=directory<>"/w"
      executable=directory<>"/launcher"
  bracket (withCString socket cServer >>= \fd -> if fd<0 then N.raise (negate fd) else pure fd) N.close $ \server -> do
    resolved <- Directory.findExecutable (Bytes.unpack tmux) >>= maybe (fail "fixture tmux executable missing") pure
    (code,_,errors) <- readProcess $ proc "cc"
      ["-std=c11","-Wall","-Wextra","-Werror","-O2","test-support/guardian-launcher.c",
       "-DLAUNCHER_MODE="<>show mode,"-DREAL_TMUX="<>show resolved,"-DWITNESS_SOCKET="<>show socket,"-o",executable]
    unless (code==ExitSuccess && Lazy.null errors) (fail (show (code,errors)))
    action (Bytes.pack executable) server

withWitness :: CInt -> ((CInt,CInt) -> IO a) -> IO a
withWitness server = bracket acquire release
  where
    acquire=allocaArray 2 $ \out -> do
      cTake server out >>= checked
      peekArray 2 out >>= \case
        [fd,peer] -> pure (fd,peer)
        _ -> fail "invalid independent witness"
    release (fd,peer)=(cRetire fd >>= checked) `finally` (N.close fd >> N.close peer)

withPending :: CInt -> ([CInt] -> IO a) -> IO a
withPending server action = cPending server >>= \case
  1 -> withWitness server $ \(fd,_) -> withPending server (action . (fd:))
  0 -> action []
  _ -> fail "invalid witness readiness"

-- Drain independent witnesses while clients execute; finite socket backlog
-- must not become a hidden launcher gate. Snapshot drains already queued peers.
withCollected :: CInt -> (IO [CInt] -> IO a) -> IO a
withCollected server action = mask $ \restore -> do
  gate <- newMVar ()
  held <- newIORef []
  let drain = cPending server >>= \case
        0 -> pure ()
        1 -> allocaArray 2 (\out -> do
          cTake server out >>= checked
          peekArray 2 out >>= \case
            [fd,peer] -> modifyIORef' held ((fd,peer):)
            _ -> fail "invalid independent witness") >> drain
        _ -> fail "invalid witness readiness"
      snapshot = withMVar gate $ \_ -> mask_ $ drain >> map fst <$> readIORef held
      reader = forever (threadWaitRead (Fd server) >> withMVar gate (const (mask_ drain)))
      release = readIORef held >>= mapM_ (\(fd,peer) ->
        (cRetire fd >>= checked) `finally` (N.close fd >> N.close peer))
  (withAsync reader (const (restore (action snapshot)))) `finally` release

-- The host is a subreaper only in a disposable test process. The candidate
-- remains a separate subreaper and supplies every production cleanup verdict.
isolated :: String -> IO () -> IO ()
isolated selected action = lookupEnv "LIBTMUX_GUARDIAN_CASE" >>= \case
  Just current | current==selected -> do
    cSubreaper >>= checked
    putStrLn marker
    action
  _ -> do
    executable <- getExecutablePath
    capabilities <- getNumCapabilities
    environment <- filter ((/= "LIBTMUX_GUARDIAN_CASE") . fst) <$> getEnvironment
    (code,output,errors) <- readProcess $ setEnv (("LIBTMUX_GUARDIAN_CASE",selected):environment) $
      setStdin nullStream $ proc executable
        ["--pattern","/"<>selected<>"/","--num-threads","1","--timeout","10s","+RTS","-N"<>show capabilities,"-RTS"]
    unless (code==ExitSuccess && Lazy.null errors) (fail (show (code,output,errors)))
    unless (Bytes.pack marker `Bytes.isInfixOf` Lazy.toStrict output && "All 1 tests passed" `Bytes.isInfixOf` Lazy.toStrict output)
      (fail "isolated witness case did not finish")
  where marker="libtmux-guardian-case: "<>selected
