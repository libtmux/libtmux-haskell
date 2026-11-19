{-# LANGUAGE ForeignFunctionInterface #-}

-- | Byte-oriented Linux primitives. The caller must journal a returned child
-- under masking and retain it through status consumption and descriptor closure.
module LibTmux.Internal.Process.Native where

import Control.Exception (Exception, evaluate, mask_, throwIO)
import Control.DeepSeq (force)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Unsafe qualified as UnsafeBytes
import Data.Word (Word8)
import Foreign.C.Error (Errno (..), eAGAIN, eCHILD, eINTR, errnoToIOError)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (sizeOf)
import GHC.Conc (closeFdWith, threadWaitWrite)
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (Fd (..))

type LaunchCall = CString -> Ptr CString -> Ptr CString -> CString -> Ptr CInt -> IO CInt
type WaitCall = CInt -> Ptr CInt -> IO CInt
type ReadCall = CInt -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall safe "libtmux_process_features" cFeatures :: IO CInt
foreign import ccall safe "libtmux_process_spawn" cSpawn :: LaunchCall
foreign import ccall safe "libtmux_process_spawn_discard_stdout" cSpawnDiscard :: LaunchCall
foreign import ccall safe "libtmux_process_wait" cWait :: WaitCall
foreign import ccall unsafe "libtmux_process_read" cRead :: CInt -> Ptr a -> CSize -> IO CInt
foreign import ccall unsafe "libtmux_process_write" cWrite :: CInt -> Ptr a -> CSize -> IO CInt
foreign import ccall unsafe "libtmux_process_signal" cSignal :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_process_group_probe" groupSignalSupport :: IO CInt
foreign import ccall unsafe "libtmux_process_group_open" cOpenGroup :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_process_group_signal" signalGroup :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_process_pidfd_open" cOpenPid :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_process_pidfd_ready" cPidReady :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_program_watch" cWatch :: CString -> IO CInt
foreign import ccall unsafe "libtmux_program_watch_read" watchRead :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_program_daemon_watch" cDaemonWatch :: CString -> CInt -> IO CInt

daemonWatch :: ByteString -> Integer -> IO CInt
daemonWatch path pid = Bytes.useAsCString path $ \socket ->
  cDaemonWatch socket (fromInteger pid) >>= \fd -> if fd < 0 then raise (-fd) else pure fd

openPid :: CInt -> IO CInt
openPid pid = cOpenPid pid >>= \fd -> if fd < 0 then raise (-fd) else pure fd

pidReady :: CInt -> IO Bool
pidReady fd = cPidReady fd >>= \value -> if value < 0 then raise (-value) else pure (value == 1)

watchDirectory :: ByteString -> IO CInt
watchDirectory path = Bytes.useAsCString path $ \name ->
  cWatch name >>= \fd -> if fd < 0 then raise (-fd) else pure fd

-- | Read an owned pidfd's kernel identity. The caller holds its descriptor
-- lifetime lock and checks liveness; a dead/reaped identity is refused.
pidfdPid :: CInt -> IO Integer
pidfdPid fd = do
  bytes <- withBinaryFile ("/proc/self/fdinfo/" <> show fd) ReadMode (\file -> Bytes.hGet file 4096)
  case [value | line <- Bytes.split 10 bytes, Just raw <- [Bytes.stripPrefix "Pid:\t" line],
         Just (value, rest) <- [Ascii.readInteger raw], Bytes.null rest, value > 0] of
    [value] -> pure value
    _ -> throwIO (InvalidInput "pidfd has no live process identity")

-- | Acquire an application group while its bootstrap is blocked. The caller
-- must additionally validate its per-run token before releasing that gate.
openGroup :: CInt -> IO CInt
openGroup pid = cOpenGroup pid >>= \fd -> if fd < 0 then raise (-fd) else pure fd

data Feature = AtomicPidfdSpawn | ChildDirectory | CloseUnrelatedDescriptors
  deriving stock (Eq, Show)

data Phase = HostFeatures | HostSignalPolicy | Pipes | FileActions | SpawnAttributes | Execute
  deriving stock (Eq, Show)

data Failure = InvalidInput !String | LaunchRefused !Phase !CInt
  deriving stock (Eq, Show)
instance Exception Failure

data Spec = Spec
  { file :: !ByteString, args :: ![ByteString], env :: ![ByteString], cwd :: !ByteString
  , discardOutput :: !Bool }

data Child = Child
  { pidfd :: !CInt, input :: !CInt, output :: !CInt, errors :: !CInt
  , collector :: !Collector }
  deriving stock (Show)

-- Collection belongs to the physical parent. A delegated pidfd remains the
-- real process identity while its parent supplies the single collected status.
data Collector = ParentStatus | DelegatedStatus !(IO (Maybe Exit))
instance Show Collector where
  show ParentStatus = "ParentStatus"
  show (DelegatedStatus _) = "DelegatedStatus"

data Start = Refused !Failure | Owned !Child
  deriving stock (Show)

data Exit = Exited !CInt | Signaled !CInt !Bool | StatusLost !CInt
  deriving stock (Eq, Show)

vectorLimitBytes, chunkBytes :: Int
vectorLimitBytes = 65536
chunkBytes = 16384

spec :: ByteString -> [ByteString] -> Spec
spec file args = Spec file args ["LANG=C.UTF-8"] "/" False

missingFeatures :: IO [Feature]
missingFeatures = do
  bits <- cFeatures
  pure [feature | (bit, feature) <- [(1, AtomicPidfdSpawn), (2, ChildDirectory),
                                    (4, CloseUnrelatedDescriptors)], bits .&. bit == 0]

-- | Bound list traversal as well as encoded bytes before entering native code.
validate :: Spec -> IO ()
validate value = do
  let countBounded n xs = length (take (n + 1) xs) <= n
      invalid = throwIO . InvalidInput
  unless (countBounded 4096 value.args && countBounded 4096 value.env)
    (invalid "native vector count limit")
  when (null value.args || length value.args + length value.env > 4096)
    (invalid "native vector count limit")
  let strings = value.file : value.cwd : value.args <> value.env
      encoded = sum (map ((+ 1) . toInteger . Bytes.length) strings)
        + toInteger (sizeOf (nullPtr :: Ptr ())) * toInteger (length value.args + length value.env + 2)
  when (encoded > toInteger vectorLimitBytes) (invalid "native vector byte limit")
  when (any (Bytes.elem 0) strings) (invalid "NUL in native launch")
  unless ("/" `Bytes.isPrefixOf` value.file && "/" `Bytes.isPrefixOf` value.cwd)
    (invalid "absolute native paths required")
  unless (all (\entry -> let (name, suffix) = Bytes.break (== 61) entry in
    not (Bytes.null name) && not (Bytes.null suffix)) value.env) (invalid "invalid environment entry")

-- | Detach retained slices after validation and before publishing to a worker.
copySpec :: Spec -> IO Spec
copySpec value = do
  validate value
  (file, args, env, cwd) <- evaluate (force
    (Bytes.copy value.file, map Bytes.copy value.args, map Bytes.copy value.env, Bytes.copy value.cwd))
  pure Spec {file, args, env, cwd, discardOutput = value.discardOutput}

launch :: Spec -> IO Start
launch value = launchWith (if value.discardOutput then cSpawnDiscard else cSpawn) value

-- | Marshal and decode during the call. The owner supplies the surrounding mask
-- that spans this return and its own child/descriptor journal.
launchWith :: LaunchCall -> Spec -> IO Start
launchWith call value = mask_ $ do
  validate value
  Bytes.useAsCString value.file $ \file -> Bytes.useAsCString value.cwd $ \cwd ->
    withMany Bytes.useAsCString value.args $ \arguments -> withArray0 nullPtr arguments $ \argv ->
      withMany Bytes.useAsCString value.env $ \entries -> withArray0 nullPtr entries $ \envp ->
        allocaArray 5 $ \result -> do
          rc <- call file argv envp cwd result
          peekArray 5 result >>= \case
            [fd, input, output, errors, 0] | rc == 0 -> pure (Owned (Child fd input output errors ParentStatus))
            [-1, -1, -1, -1, stage] | rc /= 0 -> case lookup stage phases of
              Just phase -> pure (Refused (LaunchRefused phase rc))
              Nothing -> fail "invalid native refusal stage"
            _ -> fail "invalid native ownership ABI"
  where
    phases = zip [1..] [HostFeatures, HostSignalPolicy, Pipes, FileActions, SpawnAttributes, Execute]

waitChild :: Child -> IO (Maybe Exit)
waitChild child = case child.collector of
  ParentStatus -> waitWith cWait child
  DelegatedStatus collect -> collect

-- | Consume at most one status. The owner masks and immediately caches it.
waitWith :: WaitCall -> Child -> IO (Maybe Exit)
waitWith call child = allocaArray 2 $ \result -> do
  rc <- call child.pidfd result
  if rc == 0 then pure Nothing else
    if rc == negate (errno eCHILD) then pure (Just (StatusLost (errno eCHILD))) else
    if rc < 0 then raise (-rc) else peekArray 2 result >>= \case
      [1, code] -> pure (Just (Exited code))
      [2, signal] -> pure (Just (Signaled signal False))
      [3, signal] -> pure (Just (Signaled signal True))
      _ -> fail "invalid native status ABI"

signalChild :: Child -> CInt -> IO CInt
signalChild child = cSignal child.pidfd

close :: CInt -> IO ()
close fd = when (fd >= 0) (closeFdWith Posix.closeFd (Fd fd))

readChunk :: CInt -> IO (Maybe ByteString)
readChunk = readWith cRead

-- | The owner masks the native read and publication of its returned bytes.
readWith :: ReadCall -> CInt -> IO (Maybe ByteString)
readWith call fd = allocaBytes chunkBytes $ \buffer -> do
  let loop = call fd buffer (fromIntegral chunkBytes) >>= \count ->
        if count > 0 then Just <$> Bytes.packCStringLen (castPtr buffer, fromIntegral count) else
        if count == 0 then pure (Just Bytes.empty) else
        if count == negate (errno eAGAIN) then pure Nothing else
        if count == negate (errno eINTR) then loop else raise (-count)
  loop

writeBytes :: Fd -> ByteString -> IO ()
-- The native send only reads; the pointer cannot escape this scoped action.
writeBytes (Fd fd) bytes = UnsafeBytes.unsafeUseAsCStringLen bytes $ \(buffer, size) ->
  let loop _ 0 = pure ()
      loop pointer remaining = cWrite fd pointer (fromIntegral (min remaining chunkBytes)) >>= \count ->
        if count > 0 then loop (pointer `plusPtr` fromIntegral count) (remaining - fromIntegral count) else
        if count == negate (errno eAGAIN) then threadWaitWrite (Fd fd) >> loop pointer remaining else
        if count == negate (errno eINTR) then loop pointer remaining else
        if count == 0 then fail "zero native write" else raise (-count)
  in loop buffer size

errno :: Errno -> CInt
errno (Errno value) = value

raise :: CInt -> IO a
raise value = throwIO (errnoToIOError "native process" (Errno value) Nothing Nothing)
