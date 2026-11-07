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
import Data.ByteString.Unsafe qualified as UnsafeBytes
import Foreign.C.Error (Errno (..), eAGAIN, eCHILD, eINTR, errnoToIOError)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (sizeOf)
import GHC.Conc (closeFdWith, threadWaitWrite)
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (Fd (..))

type LaunchCall = CString -> Ptr CString -> Ptr CString -> CString -> Ptr CInt -> IO CInt
type WaitCall = CInt -> Ptr CInt -> IO CInt

foreign import ccall safe "libtmux_process_features" cFeatures :: IO CInt
foreign import ccall safe "libtmux_process_spawn" cSpawn :: LaunchCall
foreign import ccall safe "libtmux_process_wait" cWait :: WaitCall
foreign import ccall unsafe "libtmux_process_read" cRead :: CInt -> Ptr a -> CSize -> IO CInt
foreign import ccall unsafe "libtmux_process_write" cWrite :: CInt -> Ptr a -> CSize -> IO CInt
foreign import ccall unsafe "libtmux_process_signal" cSignal :: CInt -> CInt -> IO CInt

data Feature = AtomicPidfdSpawn | ChildDirectory | CloseUnrelatedDescriptors
  deriving stock (Eq, Show)

data Phase = HostFeatures | HostSignalPolicy | Pipes | FileActions | SpawnAttributes | Execute
  deriving stock (Eq, Show)

data Failure = InvalidInput !String | LaunchRefused !Phase !CInt
  deriving stock (Eq, Show)
instance Exception Failure

data Spec = Spec
  { file :: !ByteString, args :: ![ByteString], env :: ![ByteString], cwd :: !ByteString }

data Child = Child
  { pidfd :: !CInt, input :: !CInt, output :: !CInt, errors :: !CInt }
  deriving stock (Show)

data Start = Refused !Failure | Owned !Child
  deriving stock (Show)

data Exit = Exited !CInt | Signaled !CInt !Bool | StatusLost !CInt
  deriving stock (Eq, Show)

vectorLimitBytes, chunkBytes :: Int
vectorLimitBytes = 65536
chunkBytes = 16384

spec :: ByteString -> [ByteString] -> Spec
spec file args = Spec file args ["LANG=C.UTF-8"] "/"

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
  pure Spec {file, args, env, cwd}

launch :: Spec -> IO Start
launch = launchWith cSpawn

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
            [fd, input, output, errors, 0] | rc == 0 -> pure (Owned (Child fd input output errors))
            [-1, -1, -1, -1, stage] | rc /= 0 -> case lookup stage phases of
              Just phase -> pure (Refused (LaunchRefused phase rc))
              Nothing -> fail "invalid native refusal stage"
            _ -> fail "invalid native ownership ABI"
  where
    phases = zip [1..] [HostFeatures, HostSignalPolicy, Pipes, FileActions, SpawnAttributes, Execute]

waitChild :: Child -> IO (Maybe Exit)
waitChild = waitWith cWait

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
readChunk fd = allocaBytes chunkBytes $ \buffer -> do
  let loop = cRead fd buffer (fromIntegral chunkBytes) >>= \count ->
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
