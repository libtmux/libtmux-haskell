{-# LANGUAGE CApiFFI #-}

module LibTmux.Internal.SocketPin
  ( PinOwner, SocketPin, PinError (..), PinReason (..), PinCheckpoint (..)
  , newPinOwner, acquirePin, acquirePinWith, closePin, pinPath, pinGeneration
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (Exception, IOException, bracket, catch, mask_, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word8)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.Types (CSize (..), CUInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import LibTmux.Internal.Graph (EndpointIdentity (..), Generation (..))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Directory.ByteString (removeDirectory)
import System.Posix.Files.ByteString qualified as File
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Temp.ByteString (mkdtemp)
import System.Posix.Types (CSsize (..), Fd, UserID)
import System.Posix.User (getEffectiveUserID)

foreign import capi unsafe "sys/random.h getrandom"
  getRandom :: Ptr Word8 -> CSize -> CUInt -> IO CSsize

foreign import capi "sys/random.h value GRND_NONBLOCK"
  randomNonblocking :: CUInt

data PinReason
  = InvalidPath | AliasTooLong | UntrustedDirectory | WrongSocketType
  | SocketOwnerMismatch | SocketNotWritable | IdentityChanged | EntropyUnavailable
  | FileSystemFailure !IOException
  deriving stock (Eq, Show)

data PinError
  = SocketPinUnavailable !PinReason
  | SocketPinCleanupFailed !PinReason
  | PinAlreadyUsed
  deriving stock (Eq, Show)
instance Exception PinError

-- The runtime keeps this owner even when acquisition or cleanup throws.
data PinOwner = PinOwner !(MVar ()) !(IORef Ownership)
data Ownership = Fresh | Acquired !(Maybe OwnedNames) | Closed
data OwnedNames = OwnedNames
  { directory :: !ByteString
  , parent :: !ByteString
  , uid :: !UserID
  , directoryIdentity :: !(Maybe EndpointIdentity)
  , alias :: !AliasOwnership
  }
data AliasOwnership
  = NoAlias
  | LinkAttempted !EndpointIdentity
  | Linked !(Maybe EndpointIdentity)
data SocketPin = SocketPin !ByteString !Generation

-- Deterministic failure/cancellation boundaries; normal acquisition observes none.
data PinCheckpoint = DirectoryRegistered | BeforeLink | LinkRegistered | BeforeEntropy | BeforePublish
  deriving stock (Eq, Show)

newPinOwner :: IO PinOwner
newPinOwner = PinOwner <$> newMVar () <*> newIORef Fresh

acquirePin :: PinOwner -> ByteString -> ByteString -> IO SocketPin
acquirePin = acquirePinWith (\_ _ -> pure ())

acquirePinWith :: (PinCheckpoint -> ByteString -> IO ()) -> PinOwner -> ByteString -> ByteString -> IO SocketPin
acquirePinWith checkpoint owner source parent = withOwner SocketPinUnavailable owner $ \owned -> do
  readIORef owned >>= \case
    Fresh -> writeIORef owned (Acquired Nothing)
    _ -> throwIO PinAlreadyUsed
  validatePath False source
  validatePath True parent
  let prefix = childPath parent "lt-"
  -- mkdtemp appends six bytes; the child socket is /s.
  when (Bytes.length prefix + 8 > 107) (unavailable AliasTooLong)
  uid <- getEffectiveUserID
  withTrustedDirectory SocketPinUnavailable uid (parentPath source) $ \_ ->
    withTrustedDirectory SocketPinUnavailable uid parent $ \parentFd -> do
      sourceStatus <- File.getSymbolicLinkStatus source
      checkSocket uid sourceStatus
      directory <- mkdtemp prefix
      let names = OwnedNames directory parent uid Nothing NoAlias
      saveNames owned names
      checkpoint DirectoryRegistered directory
      directoryStatus <- File.getSymbolicLinkStatus directory
      let identified = names {directoryIdentity = Just (identity directoryStatus)}
      saveNames owned identified
      parentStatus <- File.getFdStatus parentFd
      unless (File.isDirectory directoryStatus && File.fileOwner directoryStatus == uid
        && File.deviceID directoryStatus == File.deviceID parentStatus) $
          unavailable UntrustedDirectory
      when (File.fileMode directoryStatus .&. 0o7777 /= 0o700) $
        File.setFileMode directory 0o700
      bracket (Posix.openFdAt (Just parentFd) (leafPath directory) Posix.ReadOnly directoryFlags)
        Posix.closeFd $ \directoryFd -> do
          admitted <- File.getFdStatus directoryFd
          checkOwnedDirectory SocketPinUnavailable identified admitted
          unless (File.fileMode admitted .&. 0o7777 == 0o700) $
            unavailable UntrustedDirectory
          let alias = childPath directory "s"
              attempted = identified {alias = LinkAttempted (identity sourceStatus)}
          checkpoint BeforeLink directory
          saveNames owned attempted
          try @IOException (File.createLink source alias) >>= \case
            Left problem -> do
              -- EEXIST never grants ownership of the existing destination.
              when (isAlreadyExistsError problem) (saveNames owned identified)
              throwIO problem
            Right () -> saveNames owned (identified {alias = Linked Nothing})
          checkpoint LinkRegistered directory
          linked <- File.getSymbolicLinkStatus alias
          saveNames owned (identified {alias = Linked (Just (identity linked))})
          checkSocket uid linked
          unless (identity linked == identity sourceStatus) (unavailable IdentityChanged)
          File.getSymbolicLinkStatus directory >>= checkOwnedDirectory SocketPinUnavailable identified
          checkpoint BeforeEntropy directory
          token <- freshToken
          checkpoint BeforePublish directory
          pure (SocketPin alias (Generation (identity linked) token))

closePin :: PinOwner -> IO ()
closePin owner = withOwner SocketPinCleanupFailed owner $ \owned -> readIORef owned >>= \case
  Fresh -> writeIORef owned Closed
  Acquired Nothing -> writeIORef owned Closed
  Closed -> pure ()
  Acquired (Just names) -> statusIfPresent names.directory >>= \case
    Nothing -> writeIORef owned Closed
    Just _ -> withTrustedDirectory SocketPinCleanupFailed names.uid names.parent $ \_ -> do
      File.getSymbolicLinkStatus names.directory >>= checkOwnedDirectory SocketPinCleanupFailed names
      let alias = childPath names.directory "s"
      case names.alias of
        NoAlias -> pure ()
        LinkAttempted expected -> statusIfPresent alias >>= \case
          Nothing -> pure ()
          Just status -> do
            unless (identity status == expected) (cleanupFailed IdentityChanged)
            ignoreMissing (File.removeLink alias)
        Linked expected -> statusIfPresent alias >>= \case
          Nothing -> pure ()
          Just status -> do
            unless (maybe True (== identity status) expected) (cleanupFailed IdentityChanged)
            ignoreMissing (File.removeLink alias)
      -- Persist completed steps before an rmdir failure can return cleanup debt.
      saveNames owned (names {alias = NoAlias})
      ignoreMissing (removeDirectory names.directory)
      writeIORef owned Closed

pinPath :: SocketPin -> ByteString
pinPath (SocketPin path _) = path

pinGeneration :: SocketPin -> Generation
pinGeneration (SocketPin _ generation) = generation

withOwner :: (PinReason -> PinError) -> PinOwner -> (IORef Ownership -> IO a) -> IO a
withOwner failure (PinOwner gate owned) action = withMVar gate $ \_ -> mask_ $
  action owned `catch` (throwIO . failure . FileSystemFailure)

saveNames :: IORef Ownership -> OwnedNames -> IO ()
saveNames owned = writeIORef owned . Acquired . Just

unavailable :: PinReason -> IO a
unavailable = throwIO . SocketPinUnavailable

cleanupFailed :: PinReason -> IO a
cleanupFailed = throwIO . SocketPinCleanupFailed

validatePath :: Bool -> ByteString -> IO ()
validatePath allowRoot path
  | path == "/" = unless allowRoot (unavailable InvalidPath)
  | otherwise = when (not ("/" `Bytes.isPrefixOf` path) || Bytes.elem 0 path
      || any (\part -> Bytes.null part || part == "." || part == "..") (drop 1 (Bytes.split 47 path))) $
        unavailable InvalidPath

childPath :: ByteString -> ByteString -> ByteString
childPath parent child = parent <> (if parent == "/" then "" else "/") <> child

parentPath :: ByteString -> ByteString
parentPath path = case Bytes.breakEnd (== 47) path of
  ("/", _) -> "/"
  (prefix, _) -> Bytes.take (Bytes.length prefix - 1) prefix

leafPath :: ByteString -> ByteString
leafPath = snd . Bytes.breakEnd (== 47)

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags
  { Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True }

withTrustedDirectory :: (PinReason -> PinError) -> UserID -> ByteString -> (Fd -> IO a) -> IO a
withTrustedDirectory failure uid path action =
  bracket (Posix.openFd "/" Posix.ReadOnly directoryFlags) Posix.closeFd $ \root -> do
    check root
    walk root (if path == "/" then [] else drop 1 (Bytes.split 47 path))
  where
    walk fd [] = action fd
    walk fd (name : rest) =
      bracket (Posix.openFdAt (Just fd) name Posix.ReadOnly directoryFlags) Posix.closeFd $ \next -> do
        check next
        walk next rest
    check fd = do
      status <- File.getFdStatus fd
      let mode = File.fileMode status
          trustedOwner = File.fileOwner status == uid || File.fileOwner status == 0
          protected = mode .&. 0o022 == 0 || mode .&. 0o1000 /= 0
      unless (File.isDirectory status && trustedOwner && protected) $
        throwIO (failure UntrustedDirectory)

checkSocket :: UserID -> File.FileStatus -> IO ()
checkSocket uid status = do
  unless (File.isSocket status) (unavailable WrongSocketType)
  unless (File.fileOwner status == uid) (unavailable SocketOwnerMismatch)
  unless (File.fileMode status .&. 0o200 /= 0) (unavailable SocketNotWritable)

checkOwnedDirectory :: (PinReason -> PinError) -> OwnedNames -> File.FileStatus -> IO ()
checkOwnedDirectory failure names status = do
  unless (File.isDirectory status && File.fileOwner status == names.uid
    && maybe True (== identity status) names.directoryIdentity) $
      throwIO (failure IdentityChanged)
  unless (File.fileMode status .&. 0o077 == 0) $
    throwIO (failure UntrustedDirectory)

identity :: File.FileStatus -> EndpointIdentity
identity status = EndpointIdentity (fromIntegral (File.deviceID status)) (fromIntegral (File.fileID status))

statusIfPresent :: ByteString -> IO (Maybe File.FileStatus)
statusIfPresent path = (Just <$> File.getSymbolicLinkStatus path) `catch` \problem ->
  if isDoesNotExistError problem then pure Nothing else throwIO problem

ignoreMissing :: IO () -> IO ()
ignoreMissing action = action `catch` \problem ->
  if isDoesNotExistError problem then pure () else throwIO problem

freshToken :: IO ByteString
freshToken = allocaBytes 32 $ \buffer -> do
  count <- throwErrnoIfMinus1 "socket pin generation entropy" (getRandom buffer 32 randomNonblocking)
  unless (count == 32) (unavailable EntropyUnavailable)
  Bytes.packCStringLen (castPtr buffer, 32)
