{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE RankNTypes #-}
-- | A private execution domain. A trusted subreaper owns every admitted birth
-- until closed admission and a live ECHILD verdict prove the subtree empty.
module LibTmux.Internal.Process.Guardian where

import Control.Concurrent.Async (race_)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.Bits ((.&.), shiftR)
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.IntMap.Strict qualified as Map
import Data.Word (Word64)
import Foreign.C.Error (eAGAIN, eCHILD, eSRCH)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (free)
import Foreign.Marshal.Array (allocaArray, mallocArray, peekArray, pokeArray, withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, nullPtr)
import GHC.Conc (threadWaitRead, threadWaitWrite)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import System.Posix.Types (Fd (..))

data NativeRequest
data DomainError = DomainClosed | GuardianLost | InvalidGuardianReply
  deriving stock (Eq, Show)
instance Exception DomainError

data Entry = Entry
  { native :: !(IORef (Maybe (Ptr NativeRequest))), sent :: !(TVar Bool)
  , birth :: !(TMVar (Either DomainError (Maybe CInt)))
  , status :: !(TMVar (Either DomainError N.Exit))
  }
data Domain = Domain
  { native :: !(Ptr CInt), lease :: !B.ChildLease, forker :: !P.Fork
  , sendGate :: !(MVar ()), receiveGate :: !(MVar ()), ready :: !(TMVar ())
  , entries :: !(TVar (Map.IntMap Entry)), authentications :: !(TVar (Map.IntMap (TMVar (Either DomainError Bool))))
  , next :: !(TVar Int), reader :: !(TVar Bool), readerDone :: !(TMVar ())
  , closed :: !(TVar Bool), sentAny :: !(TVar Bool), stopped :: !(TVar Bool)
  , full :: !(TVar Bool), lost :: !(TVar Bool), released :: !(TVar Bool)
  , helperExit :: !(IORef (Maybe N.Exit))
  }

foreign import ccall safe "libtmux_guardian_start" cStart :: Ptr CInt -> IO CInt
foreign import ccall unsafe "libtmux_guardian_prepare" cPrepare
  :: CString -> Ptr CString -> Ptr CString -> CString -> CInt -> Ptr CInt -> IO (Ptr NativeRequest)
foreign import ccall unsafe "libtmux_guardian_send" cSend
  :: CInt -> CInt -> CInt -> CInt -> Ptr NativeRequest -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_guardian_receive" cReceive :: CInt -> Ptr CInt -> IO CInt
foreign import ccall unsafe "libtmux_guardian_accept" cAccept :: Ptr NativeRequest -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_guardian_take" cTake :: Ptr NativeRequest -> Ptr CInt -> IO ()
foreign import ccall unsafe "libtmux_guardian_commit" cCommit :: Ptr NativeRequest -> IO ()
foreign import ccall unsafe "libtmux_guardian_retire" cRetire :: Ptr NativeRequest -> IO ()

transportBytes, guardianBytes :: Word64
transportBytes = fromIntegral N.vectorLimitBytes
guardianBytes = 512 * 1024

-- No process can exist yet. The enclosing owner journals this context before
-- 'startDomain'; failure after the native call always leaves it reachable.
prepareDomain :: B.Budget -> P.Fork -> IO Domain
prepareDomain budget forker = mask_ $ do
  lease <- atomically (B.acquireChild budget B.Ordinary guardianBytes)
  let build = do
        native <- mallocArray 3
        pokeArray native [-1,-1,-1]
        -- The native launcher initializes all entries before attempting birth.
        sendGate <- newMVar ()
        receiveGate <- newMVar ()
        ready <- newEmptyTMVarIO
        entries <- newTVarIO Map.empty
        authentications <- newTVarIO Map.empty
        next <- newTVarIO 0
        reader <- newTVarIO False
        readerDone <- newEmptyTMVarIO
        closed <- newTVarIO False
        sentAny <- newTVarIO False
        stopped <- newTVarIO False
        full <- newTVarIO False
        lost <- newTVarIO False
        released <- newTVarIO False
        helperExit <- newIORef Nothing
        pure Domain {native,lease,forker,sendGate,receiveGate,ready,entries,authentications,next,reader,readerDone,
          closed,sentAny,stopped,full,lost,released,helperExit}
  build `onException` atomically (B.releaseChild lease)

startDomain :: Domain -> IO ()
startDomain domain = mask_ $ do
  rc <- cStart domain.native
  when (rc /= 0) $ do
    free domain.native
    atomically $ writeTVar domain.released True >> B.releaseChild domain.lease
    N.raise rc
  ensureReader domain
  atomically $ (readTMVar domain.ready >> pure ()) `orElse`
    (readTVar domain.lost >>= check >> throwSTM GuardianLost)

nativeDescriptors :: Domain -> IO (CInt,CInt)
nativeDescriptors domain = peekArray 3 domain.native >>= \case
  [channel,helper,_] -> pure (channel,helper)
  _ -> throwIO InvalidGuardianReply

forkDomain :: Domain -> P.Fork
forkDomain Domain {forker} = forker

ensureReader :: Domain -> IO ()
ensureReader domain = mask_ $ do
  claimed <- atomically $ do
    running <- readTVar domain.reader
    if running then pure False else writeTVar domain.reader True >> pure True
  when claimed $ void (forkDomain domain $ \_ -> do
    let events = do
          (channel,_) <- nativeDescriptors domain
          let loop = do
                threadWaitRead (Fd channel)
                drain domain
                finished <- readTVarIO domain.full
                unless finished loop
          loop
        exited = do
          (_,helper) <- nativeDescriptors domain
          threadWaitRead (Fd helper)
          drain domain
        observe = race_ events exited
    outcome <- try @SomeException observe
    atomically $ do
      complete <- readTVar domain.full
      unless complete $ do
        writeTVar domain.lost True
        pending <- readTVar domain.entries
        forM_ pending $ \entry -> do
          void (tryPutTMVar entry.birth (Left GuardianLost))
          void (tryPutTMVar entry.status (Left GuardianLost))
        readTVar domain.authentications >>= mapM_ (\reply -> void (tryPutTMVar reply (Left GuardianLost)))
      void (tryPutTMVar domain.readerDone ())
    either (const (pure ())) pure outcome)
    `onException` atomically (writeTVar domain.reader False)

-- One reader gate protects reply decoding against concurrent drain calls.
-- All predicates live in STM; a dispatched reply cannot lose its wakeup.
drain :: Domain -> IO ()
drain domain = withMVar domain.receiveGate $ \_ -> mask_ $ do
  (channel,_) <- nativeDescriptors domain
  let loop = allocaArray 5 $ \output -> cReceive channel output >>= \case
        0 -> pure ()
        1 -> peekArray 5 output >>= dispatch domain >> loop
        _ -> readTVarIO domain.full >>= flip unless (throwIO GuardianLost)
  loop

dispatch :: Domain -> [CInt] -> IO ()
dispatch domain [op,key,_arg,code,fd] = do
  let reject :: IO a
      reject = N.close fd >> throwIO InvalidGuardianReply
      known action = do
        entry <- atomically (Map.lookup (fromIntegral key) <$> readTVar domain.entries)
        maybe reject action entry
  case op of
    1 | key == 0 && fd < 0 -> atomically (putTMVar domain.ready ())
    5 | key == 0 && code == N.errno eCHILD && fd < 0 -> atomically (writeTVar domain.full True)
    2 | fd >= 0 -> known $ \entry -> do
      pointer <- readIORef entry.native >>= maybe reject pure
      rc <- cAccept pointer fd
      when (rc /= 0) reject
      atomically (putTMVar entry.birth (Right Nothing))
    3 | fd < 0 -> known $ \entry -> atomically $ do
      let status = if code .&. 127 == 0 then N.Exited (code `shiftR` 8)
            else N.Signaled (code .&. 127) (code .&. 128 /= 0)
      putTMVar entry.status (Right status)
    4 | fd >= 0 -> do
      N.close fd
      answer True
    8 | fd < 0 -> do
      auth <- atomically (Map.lookup (fromIntegral key) <$> readTVar domain.authentications)
      case auth of
        Just reply -> atomically $ do
          putTMVar reply (Right False)
          modifyTVar' domain.authentications (Map.delete (fromIntegral key))
        Nothing -> known $ \entry -> atomically (putTMVar entry.birth (Right (Just code)))
    _ -> reject
  where
    answer value = atomically $ do
      auth <- Map.lookup (fromIntegral key) <$> readTVar domain.authentications
      maybe (throwSTM InvalidGuardianReply) (\reply -> putTMVar reply (Right value)) auth
      modifyTVar' domain.authentications (Map.delete (fromIntegral key))
-- Malformed replies never transfer a descriptor silently.
dispatch _ values = mapM_ N.close (drop 4 values) >> throwIO InvalidGuardianReply

newKey :: Domain -> STM Int
newKey domain = do
  closed <- readTVar domain.closed
  lost <- readTVar domain.lost
  when closed (throwSTM DomainClosed)
  when lost (throwSTM GuardianLost)
  previous <- readTVar domain.next
  when (previous >= fromIntegral (maxBound :: CInt)) (throwSTM P.ResourceLimit)
  writeTVar domain.next (previous+1)
  pure (previous+1)

send :: Domain -> CInt -> Int -> Ptr NativeRequest -> CInt -> IO ()
send domain op key request fd = withMVar domain.sendGate $ \_ -> mask_ $ do
  (channel,_) <- nativeDescriptors domain
  let loop = cSend channel op (fromIntegral key) 0 request fd >>= \rc ->
        if rc == N.errno eAGAIN then threadWaitWrite (Fd channel) >> loop
        else when (rc /= 0) (N.raise rc)
  when (op==10) $ atomically $ do
    closed <- readTVar domain.closed
    when closed (throwSTM DomainClosed)
  loop

backend :: Domain -> P.Backend
backend domain = P.Backend transportBytes $ \_allocation spec -> mask_ $ do
  N.validate spec
  key <- atomically (newKey domain)
  pointer <- Bytes.useAsCString spec.file $ \file -> Bytes.useAsCString spec.cwd $ \cwd ->
    withMany Bytes.useAsCString spec.args $ \args -> withArray0 nullPtr args $ \argv ->
      withMany Bytes.useAsCString spec.env $ \env -> withArray0 nullPtr env $ \environment ->
        allocaArray 1 $ \failureOut -> do
          pointer <- cPrepare file argv environment cwd (if spec.discardOutput then 1 else 0) failureOut
          when (pointer == nullPtr) (peekArray 1 failureOut >>= mapM_ N.raise)
          pure pointer
  native <- newIORef (Just pointer)
  sent <- newTVarIO False
  birth <- newEmptyTMVarIO
  status <- newEmptyTMVarIO
  let entry = Entry {native,sent,birth,status}
  atomically (modifyTVar' domain.entries (Map.insert key entry))
  pure P.Prepared
    { P.startPrepared = do
        send domain 10 key pointer (-1)
        atomically $ writeTVar entry.sent True >> writeTVar domain.sentAny True
        awaitStart domain key entry spec
    , P.publishPrepared = do
        readIORef entry.native >>= mapM_ cCommit
        writeIORef entry.native Nothing
    , P.retirePrepared = retirePending domain key entry spec }

awaitStart :: Domain -> Int -> Entry -> N.Spec -> IO N.Start
awaitStart domain key entry spec = atomically (readTMVar entry.birth) >>= either throwIO (\case
  Just failure -> do
    retireStorage domain key entry
    pure (N.Refused (N.LaunchRefused N.Execute failure))
  Nothing -> do
    pointer <- readIORef entry.native >>= maybe (throwIO InvalidGuardianReply) pure
    N.launchWith (\_ _ _ _ output -> cTake pointer output >> pure 0) spec >>= \case
      N.Refused problem -> pure (N.Refused problem)
      N.Owned child -> pure (N.Owned (child {N.collector = N.DelegatedStatus (collect domain key entry)})))

collect :: Domain -> Int -> Entry -> IO (Maybe N.Exit)
collect domain key entry = do
  status <- atomically (readTMVar entry.status) >>= either throwIO pure
  atomically (modifyTVar' domain.entries (Map.delete key))
  pure (Just status)

retireStorage :: Domain -> Int -> Entry -> IO ()
retireStorage domain key entry = mask_ $ do
  readIORef entry.native >>= mapM_ cRetire
  writeIORef entry.native Nothing
  atomically (modifyTVar' domain.entries (Map.delete key))

retirePending :: Domain -> Int -> Entry -> N.Spec -> IO ()
retirePending domain key entry spec = do
  wasSent <- readTVarIO entry.sent
  if not wasSent then retireStorage domain key entry else do
    send domain 14 key nullPtr (-1)
    awaitStart domain key entry spec >>= \case
      N.Refused _ -> pure ()
      N.Owned child -> do
        rc <- N.signalChild child 9
        when (rc /= 0 && rc /= N.errno eSRCH) (N.raise rc)
        threadWaitRead (Fd child.pidfd)
        _ <- collect domain key entry
        retireStorage domain key entry

-- Authenticate membership without adopting arbitrary host processes. The helper
-- lists only its own unreaped children before comparing retained pidfds.
authenticate :: Domain -> CInt -> IO Bool
authenticate domain pidfd = mask_ $ do
  reply <- newEmptyTMVarIO
  key <- atomically $ do
    key <- newKey domain
    modifyTVar' domain.authentications (Map.insert key reply)
    pure key
  send domain 12 key nullPtr pidfd
  atomically (readTMVar reply) >>= either throwIO pure

requestStop :: Domain -> IO ()
requestStop domain = mask_ $ do
  ensureReader domain
  atomically (writeTVar domain.closed True)
  stopped <- readTVarIO domain.stopped
  unless stopped $ do
    send domain 11 0 nullPtr (-1) `catch` \(problem :: IOException) -> do
      drain domain
      complete <- readTVarIO domain.full
      unless complete (throwIO problem)
    atomically (writeTVar domain.stopped True)

awaitStopped :: Domain -> IO ()
awaitStopped domain = do
  atomically $ do
    full <- readTVar domain.full
    lost <- readTVar domain.lost
    unless full $ if lost then throwSTM GuardianLost else retry
  (_,helper) <- nativeDescriptors domain
  threadWaitRead (Fd helper)
  mask_ $ readIORef domain.helperExit >>= \case
    Just _ -> pure ()
    Nothing -> do
      let child = N.Child helper (-1) (-1) (-1) N.ParentStatus
      N.waitChild child >>= \case
        Nothing -> throwIO InvalidGuardianReply
        Just (N.StatusLost _) -> throwIO GuardianLost
        Just status -> writeIORef domain.helperExit (Just status)

releaseDomain :: Domain -> IO ()
releaseDomain domain = mask_ $ do
  complete <- readTVarIO domain.released
  unless complete $ do
    awaitStopped domain
    atomically (readTMVar domain.readerDone)
    active <- readTVarIO domain.entries
    unless (Map.null active) (throwIO InvalidGuardianReply)
    (channel,helper) <- nativeDescriptors domain
    N.close channel
    N.close helper
    free domain.native
    atomically $ writeTVar domain.released True >> B.releaseChild domain.lease

isReleased :: Domain -> IO Bool
isReleased = readTVarIO . (.released)
