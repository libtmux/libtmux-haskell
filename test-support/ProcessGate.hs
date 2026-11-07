{-# LANGUAGE ForeignFunctionInterface #-}
module ProcessGate where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
import Control.Exception (bracket, finally, mask_, onException)
import Control.Monad (void, when)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr qualified
import Foreign.Marshal.Array (allocaArray, peekArray)
import GHC.Conc (threadWaitRead)
import LibTmux.Internal.Process.Native qualified as N
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (Fd (..))

foreign import ccall unsafe "libtmux_test_watch_writer" cWatchWriter :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_test_control_pipe" cPipe :: Foreign.Ptr.Ptr CInt -> IO CInt
foreign import ccall safe "libtmux_test_spawn_gate" cSpawnGate :: CInt -> CInt -> CInt -> N.LaunchCall
foreign import ccall safe "libtmux_test_wait_gate" cWaitGate :: CInt -> CInt -> N.WaitCall

data GatePoint = BeforeLaunch | AfterLaunch deriving stock (Eq, Show)
data GateState = Fresh | Using | Returned | Closed deriving stock (Eq)
data Gate = Gate !CInt !CInt !CInt !CInt !(TVar GateState) !(TVar Bool) !(TVar (Maybe ThreadId))

launch :: GatePoint -> Gate -> N.Spec -> IO N.Start
launch point gate spec = usingGate (Just gate) $ \fd notice ->
  N.launchWith (cSpawnGate (if point == BeforeLaunch then 1 else 2) fd notice) spec

consume :: Gate -> N.Child -> IO (Maybe N.Exit)
consume gate child = usingGate (Just gate) $ \fd notice -> N.waitWith (cWaitGate fd notice) child

watchWriter :: Gate -> N.Child -> IO ()
watchWriter (Gate _ _ _ notice _ _ _) child = do
  rc <- cWatchWriter child.input notice
  when (rc /= 0) (N.raise rc)

stopWatchingWriter :: IO ()
stopWatchingWriter = void (cWatchWriter (-1) (-1))

-- Test gates hold the actual native call before returning to the RTS.
withGate :: (Gate -> IO a) -> IO a
withGate = bracket acquire release
  where
    acquire = do
      [readEnd, writeEnd] <- pipe
      [noticeRead, noticeWrite] <- pipe `onException` mapM_ N.close [readEnd, writeEnd]
      Gate readEnd writeEnd noticeRead noticeWrite <$> newTVarIO Fresh <*> newTVarIO False <*> newTVarIO Nothing
    release gate@(Gate a b c d state _ _) = do
      releaseGate gate
      atomically $ readTVar state >>= \case
        Using -> retry
        _ -> writeTVar state Closed
      mapM_ N.close [a,b,c,d]
    pipe = allocaArray 2 $ \fds -> do
      rc <- cPipe fds
      if rc == 0 then peekArray 2 fds else N.raise rc

usingGate :: Maybe Gate -> (CInt -> CInt -> IO a) -> IO a
usingGate Nothing action = action (-1) (-1)
usingGate (Just (Gate readEnd _ _ noticeWrite state _ thread)) action = mask_ $ do
  identity <- myThreadId
  atomically $ readTVar state >>= \case
    Fresh -> writeTVar state Using >> writeTVar thread (Just identity)
    _ -> throwSTM (userError "gate already used or closed")
  action readEnd noticeWrite `finally` atomically (writeTVar state Returned)

awaitGate :: Gate -> IO ()
awaitGate (Gate _ _ noticeRead _ _ _ _) = do
  threadWaitRead (Fd noticeRead)
  N.readChunk noticeRead >>= \case
    Just "\1" -> pure ()
    _ -> fail "invalid native gate receipt"

releaseGate :: Gate -> IO ()
releaseGate (Gate _ writeEnd _ _ _ released _) = mask_ $ do
  first <- atomically $ readTVar released >>= \done -> writeTVar released True >> pure (not done)
  when first (void (Posix.fdWrite (Fd writeEnd) "\1"))

-- | Identify the native caller before its gate receipt; no return-path hook.
gateThread :: Gate -> STM ThreadId
gateThread (Gate _ _ _ _ _ _ identity) = readTVar identity >>= maybe retry pure
