{-# LANGUAGE ForeignFunctionInterface #-}
-- | Disposable adapter for the private process membership experiment.
module GuardianDriver where

import Control.Exception (bracket, finally, mask, mask_, onException, throwIO)
import Control.Concurrent.STM (atomically, newTVarIO)
import Control.Monad (unless, when)
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.Word (Word64)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (allocaArray, peekArray, withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, nullPtr)
import GHC.Conc (threadWaitRead)
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import System.Directory (removePathForcibly)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))

data NativeContext
data Context = Context {native :: !(Ptr NativeContext), latest :: !(IORef CInt)}
data Mode = Published | Unpublished | DispatchedFirst deriving stock (Eq)

foreign import ccall safe "libtmux_test_guardian_alloc" cAlloc :: IO (Ptr NativeContext)
foreign import ccall safe "libtmux_test_guardian_start" cStart :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_prepare" cPrepare
  :: Ptr NativeContext -> CString -> Ptr CString -> Ptr CString -> CString -> CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_begin" cBegin :: Ptr NativeContext -> CInt -> Ptr CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_wait" cWait :: Ptr NativeContext -> CInt -> Ptr CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_retire_pending" cRetirePending :: Ptr NativeContext -> CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_kill" cKill :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_count" cCount :: Ptr NativeContext -> CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_full" cFull :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_notice" cNotice :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_force_peer_exit" cForcePeerExit :: Ptr NativeContext -> IO ()
foreign import ccall safe "libtmux_test_guardian_diagnostic" cDiagnostic :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_prepared_count" cPreparedCount :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_collected_count" cCollectedCount :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_serialized_bytes" cSerializedBytes :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_release" cRelease :: Ptr NativeContext -> IO CInt
foreign import ccall safe "libtmux_test_guardian_fixture_subreaper" cSubreaper :: IO CInt
foreign import ccall safe "libtmux_test_guardian_witness_server" cWitnessServer :: CString -> IO CInt
foreign import ccall safe "libtmux_test_guardian_witness_take" cWitnessTake :: CInt -> Ptr CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_fixture_retire" cFixtureRetire :: CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_witness_exited" cWitnessExited :: CInt -> IO CInt
foreign import ccall safe "libtmux_test_guardian_fixture_collect_helper" cCollectHelper :: Ptr NativeContext -> IO CInt

checked :: CInt -> IO ()
checked rc = unless (rc == 0) (N.raise (abs rc))

withContext :: Bool -> (Context -> IO a) -> IO a
withContext retained action = mask $ \restore -> do
  context <- acquire
  cleanupFailure <- newTVarIO Nothing
  P.preservingFinally cleanupFailure (restore (action context) `onException` diagnostic context) (release context)
  where
    acquire = mask_ $ do
      native <- cAlloc
      when (native == nullPtr) (throwIO (userError "guardian context allocation failed"))
      context <- Context native <$> newIORef 0
      cStart native >>= checked
      pure context
    release context = cRelease context.native >>= \rc ->
      if retained
        then unless (rc < 0) (throwIO (userError "lost guardian owner was unexpectedly released"))
        else checked rc
    diagnostic context = do
      status <- cDiagnostic context.native
      prepared <- cPreparedCount context.native
      collected <- cCollectedCount context.native
      putStrLn ("guardian diagnostic: helper=" <> show status <> " prepared=" <> show prepared <> " collected=" <> show collected)

prepare :: Context -> Mode -> N.Spec -> IO CInt
prepare context mode spec = N.validate spec >>
  Bytes.useAsCString spec.file (\file -> Bytes.useAsCString spec.cwd $ \cwd ->
    withMany Bytes.useAsCString spec.args $ \args -> withArray0 nullPtr args $ \argv ->
      withMany Bytes.useAsCString spec.env $ \env -> withArray0 nullPtr env $ \environment -> do
        key <- cPrepare context.native file argv environment cwd (case mode of Unpublished -> 1; DispatchedFirst -> 2; Published -> 0)
        when (key < 0) (N.raise (negate key))
        writeIORef context.latest key
        pure key)

begin :: Context -> CInt -> N.Spec -> IO N.Start
begin context key = N.launchWith $ \_ _ _ _ result -> do
  rc <- cBegin context.native key result
  when (rc < 0) (throwIO (userError "delegated launch reply was withheld"))
  pure rc

backendHooks :: P.Pool -> Context -> Mode -> IO () -> IO P.Hooks
backendHooks pool context mode beforeCleanup = do
  atomically $ P.bindBackend pool P.Backend
    { P.payloadAllowance = transportBytes
    , P.prepareBackend = \_allocation spec -> do
        key <- prepare context mode spec
        pure P.Prepared
          { P.startPrepared = begin context key spec >>= \case
              N.Refused failure -> pure (N.Refused failure)
              N.Owned child -> pure (N.Owned (child
                {N.collector = N.DelegatedStatus (collect context key child)}))
          , P.retirePrepared = beforeCleanup >> retirePending context key } }
  pure P.defaultHooks

transportBytes :: Word64
transportBytes = fromIntegral N.vectorLimitBytes

collect :: Context -> CInt -> N.Child -> IO (Maybe N.Exit)
collect context key = N.waitWith (\_ result -> do
  rc <- cWait context.native key result
  when (rc < 0) (N.raise (negate rc))
  pure rc)

retirePending :: Context -> CInt -> IO ()
retirePending context key = cRetirePending context.native key >>= checked

killHelper :: Context -> IO ()
killHelper context = cKill context.native >>= checked

collectHelper :: Context -> IO ()
collectHelper context = cCollectHelper context.native >>= checked

witnessExited :: CInt -> IO Bool
witnessExited witness = (== 1) <$> cWitnessExited witness

collections :: Context -> IO CInt
collections context = readIORef context.latest >>= cCount context.native

fullProof :: Context -> IO Bool
fullProof context = (== 1) <$> cFull context.native

preparedCount :: Context -> IO CInt
preparedCount = cPreparedCount . (.native)

collectedCount :: Context -> IO CInt
collectedCount = cCollectedCount . (.native)

serializedBytes :: Context -> IO CInt
serializedBytes = cSerializedBytes . (.native)

awaitDispatched :: Context -> IO ()
awaitDispatched context = do
  fd <- cNotice context.native
  threadWaitRead (Fd fd)
  N.readChunk fd >>= \case
    Just "\1" -> pure ()
    _ -> fail "invalid dispatched-response checkpoint"

forcePeerExit :: Context -> IO ()
forcePeerExit = cForcePeerExit . (.native)

withWitnessServer :: (FilePath -> CInt -> IO a) -> IO a
withWitnessServer action = bracket (mkdtemp "/tmp/libtmux-guardian-") removePathForcibly $ \directory -> do
  let path = directory <> "/w"
  bracket (withCString path cWitnessServer >>= \fd -> if fd < 0 then N.raise (negate fd) else pure fd)
    N.close (action path)

takeWitness :: CInt -> IO (CInt, CInt)
takeWitness server = allocaArray 2 $ \result -> do
  cWitnessTake server result >>= checked
  peekArray 2 result >>= \case
    [witness, peer] -> pure (witness, peer)
    _ -> fail "invalid independent witness response"

withWitness :: CInt -> ((CInt, CInt) -> IO a) -> IO a
withWitness server = bracket (takeWitness server) (\(witness, peer) ->
  (cFixtureRetire witness >>= checked) `finally` (N.close witness >> N.close peer))
