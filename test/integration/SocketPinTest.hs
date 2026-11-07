module SocketPinTest (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (AsyncCancelled (..), cancel, race, wait, waitCatch, withAsync)
import Control.Exception (IOException, bracket, catch, finally, fromException, throwIO, try)
import Control.Monad (forM_, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.List (sort)
import Fixture (Fixture (..), command, withFixture)
import LibTmux.Internal.Graph (EndpointIdentity (..), Generation (..))
import LibTmux.Internal.SocketPin
import System.Directory (removePathForcibly)
import System.Exit (ExitCode (..))
import System.IO.Error (ioeGetErrorString, isAlreadyExistsError, isDoesNotExistError)
import System.OsPath.Posix qualified as OsPath
import System.OsString.Posix qualified as OsString
import System.Posix.Directory.ByteString qualified as Directory
import System.Posix.Files.ByteString qualified as File
import System.Posix.Temp.ByteString (mkdtemp)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "private socket pin"
  [ testCase "public replacement cannot retarget the linked socket" $
      withFixture $ \original -> withFixture $ \replacement -> do
        let source = Ascii.pack original.socket
            parent = Ascii.pack original.directory
        pinned <- bracket newPinOwner closePin $ \owner -> do
          pin <- acquirePin owner source parent
          assertBool "pin uses public path" (pinPath pin /= source)
          status <- File.getSymbolicLinkStatus (parentOf (pinPath pin))
          File.fileMode status .&. 0o7777 @?= 0o700
          originalStatus <- File.getSymbolicLinkStatus source
          File.removeLink source
          File.createLink (Ascii.pack replacement.socket) source
          path <- decodePath (pinPath pin)
          (code, output, errors) <- command (original {socket = path})
            ["rename-session", "-t", "fixture", "pinned"]
          (code, output, errors) @?= (ExitSuccess, "", "")
          (_, name, _) <- command replacement ["list-sessions", "-F", "#{session_name}"]
          name @?= "fixture\n"
          pinnedStatus <- File.getSymbolicLinkStatus (pinPath pin)
          identity pinnedStatus @?= identity originalStatus
          pure pin
        assertAbsent (pinPath pinned)
        assertAbsent (parentOf (pinPath pinned))
        current <- File.getSymbolicLinkStatus source
        other <- File.getSymbolicLinkStatus (Ascii.pack replacement.socket)
        identity current @?= identity other
  , testCase "same inode acquisitions get independent generation tokens" $
      withFixture $ \fixture ->
        bracket newPinOwner closePin $ \firstOwner ->
          bracket newPinOwner closePin $ \secondOwner -> do
            first <- acquirePin firstOwner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
            second <- acquirePin secondOwner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
            let Generation firstIdentity firstToken = pinGeneration first
                Generation secondIdentity secondToken = pinGeneration second
            firstIdentity @?= secondIdentity
            Bytes.length firstToken @?= 32
            Bytes.length secondToken @?= 32
            assertBool "generation was reused" (firstToken /= secondToken)
  , testCase "non-sockets, symlink leaves and non-writable sockets are refused" $
      withFixture $ \fixture -> do
        let parent = Ascii.pack fixture.directory
            source = Ascii.pack fixture.socket
            regular = parent <> "/regular"
            fifo = parent <> "/fifo"
            directory = parent <> "/directory"
            symlink = parent <> "/symlink"
        Bytes.writeFile (fixture.directory <> "/regular") "sentinel"
        File.createNamedPipe fifo 0o600
        Directory.createDirectory directory 0o700
        File.createSymbolicLink source symlink
        before <- entries parent
        forM_ [regular, fifo, directory, symlink] $ \path ->
          bracket newPinOwner closePin $ \owner ->
            expectUnavailable WrongSocketType (acquirePin owner path parent)
        bracket newPinOwner closePin $ \owner -> do
          File.setFileMode source 0o400
          expectUnavailable SocketNotWritable (acquirePin owner source parent)
            `finally` File.setFileMode source 0o660
        entries parent >>= (@?= before)
        Bytes.readFile (fixture.directory <> "/regular") >>= (@?= "sentinel")
  , testCase "unsafe and symlink ancestors cannot host or select a pin" $
      withFixture $ \fixture -> do
        let parent = Ascii.pack fixture.directory
            source = Ascii.pack fixture.socket
            unsafe = parent <> "/unsafe"
            child = unsafe <> "/child"
            symlink = parent <> "/indirect"
        Directory.createDirectory unsafe 0o700
        Directory.createDirectory child 0o700
        File.setFileMode unsafe 0o770
        File.createSymbolicLink parent symlink
        File.createLink source (child <> "/socket")
        forM_ [(source, child), (child <> "/socket", parent)] $ \(endpoint, pinParent) ->
          bracket newPinOwner closePin $ \owner ->
            expectUnavailable UntrustedDirectory (acquirePin owner endpoint pinParent)
        forM_ [(source, symlink), (symlink <> "/socket", parent)] $ \(endpoint, pinParent) ->
          bracket newPinOwner closePin $ \owner -> do
            result <- try @PinError (acquirePin owner endpoint pinParent)
            case result of
              Left (SocketPinUnavailable _) -> pure ()
              _ -> assertFailure "symlink directory was followed"
  , testCase "ambiguous and NUL paths fail before creating names" $
      withFixture $ \fixture -> do
        let parent = Ascii.pack fixture.directory
            source = Ascii.pack fixture.socket
        before <- entries parent
        forM_ ["", "relative", source <> "\0ignored", parent <> "/./socket", parent <> "//socket"] $ \path ->
          bracket newPinOwner closePin $ \owner ->
            expectUnavailable InvalidPath (acquirePin owner path parent)
        forM_ ["", "relative", parent <> "\0ignored", parent <> "/..", parent <> "/"] $ \path ->
          bracket newPinOwner closePin $ \owner ->
            expectUnavailable InvalidPath (acquirePin owner source path)
        entries parent >>= (@?= before)
  , testCase "raw bytes survive the 107-byte socket address boundary" $
      withFixture $ \fixture -> do
        let base = Ascii.pack fixture.directory
            parent = base <> "/" <> Bytes.replicate (93 - Bytes.length base) 120 <> "\255"
            tooLong = parent <> "x"
        Bytes.length parent @?= 95
        bracket (Directory.createDirectory parent 0o700) (const (Directory.removeDirectory parent)) $ \_ ->
          bracket newPinOwner closePin $ \owner -> do
            pin <- acquirePin owner (Ascii.pack fixture.socket) parent
            Bytes.length (pinPath pin) @?= 107
            linked <- File.getSymbolicLinkStatus (pinPath pin)
            source <- File.getSymbolicLinkStatus (Ascii.pack fixture.socket)
            identity linked @?= identity source
        bracket (Directory.createDirectory tooLong 0o700) (const (Directory.removeDirectory tooLong)) $ \_ -> do
          bracket newPinOwner closePin $ \owner ->
            expectUnavailable AliasTooLong (acquirePin owner (Ascii.pack fixture.socket) tooLong)
          entries tooLong >>= (@?= [])
  , testCase "caller cancellation leaves the pin with its explicit owner" $
      withFixture $ \fixture -> bracket newPinOwner closePin $ \owner -> do
        ready <- newEmptyMVar
        never <- newEmptyMVar @()
        withAsync (do
          pin <- acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          putMVar ready pin
          takeMVar never) $ \worker -> do
            race (wait worker) (takeMVar ready) >>= \case
              Left () -> assertFailure "worker returned before cancellation"
              Right pin -> do
                cancel worker
                waitCatch worker >>= \case
                  Left problem | Just AsyncCancelled <- fromException problem -> pure ()
                  _ -> assertFailure "cancellation was replaced by another result"
                File.getSymbolicLinkStatus (pinPath pin) >>= assertBool "pin disappeared" . File.isSocket
                closePin owner
                assertAbsent (pinPath pin)
                assertAbsent (parentOf (pinPath pin))
  , testCase "registered acquisition resources survive cancellation at each boundary" $
      withFixture $ \fixture ->
        forM_ [DirectoryRegistered, BeforeLink, LinkRegistered, BeforeEntropy, BeforePublish] $ \boundary ->
          bracket newPinOwner closePin $ \owner -> do
            ready <- newEmptyMVar
            never <- newEmptyMVar @()
            let checkpoint step directory = when (step == boundary) $
                  putMVar ready directory >> takeMVar never
            withAsync (acquirePinWith checkpoint owner (Ascii.pack fixture.socket)
              (Ascii.pack fixture.directory)) $ \worker -> do
                race (wait worker) (takeMVar ready) >>= \case
                  Left _ -> assertFailure ("acquisition skipped " <> show boundary)
                  Right directory -> do
                    cancel worker
                    waitCatch worker >>= \case
                      Left problem | Just AsyncCancelled <- fromException problem -> pure ()
                      _ -> assertFailure "acquisition cancellation was converted or lost"
                    closePin owner
                    assertAbsent directory
                    File.getSymbolicLinkStatus (Ascii.pack fixture.socket) >> pure ()
  , testCase "registered resources remain recoverable after fallible acquisition steps" $
      withFixture $ \fixture ->
        forM_ [DirectoryRegistered, LinkRegistered, BeforeEntropy] $ \boundary ->
          bracket newPinOwner closePin $ \owner -> do
            reached <- newEmptyMVar
            let checkpoint step directory = when (step == boundary) $
                  putMVar reached directory >> throwIO (userError "injected pin acquisition failure")
            try @PinError (acquirePinWith checkpoint owner (Ascii.pack fixture.socket)
              (Ascii.pack fixture.directory)) >>= \case
                Left (SocketPinUnavailable (FileSystemFailure cause)) ->
                  ioeGetErrorString cause @?= "injected pin acquisition failure"
                _ -> assertFailure "acquisition did not preserve the injected IO failure"
            directory <- takeMVar reached
            File.getSymbolicLinkStatus directory >>= assertBool "untracked directory" . File.isDirectory
            when (boundary /= DirectoryRegistered) $
              File.getSymbolicLinkStatus (directory <> "/s") >>= assertBool "untracked alias" . File.isSocket
            closePin owner
            assertAbsent directory
  , testCase "source changes before link fail admission and preserve public replacements" $
      withFixture $ \fixture -> withFixture $ \replacement -> do
        let source = Ascii.pack fixture.socket
            saved = Ascii.pack fixture.directory <> "/original"
            other = Ascii.pack replacement.socket
        forM_ [(False, IdentityChanged), (True, WrongSocketType)] $ \(symlink, expected) ->
          bracket newPinOwner closePin $ \owner -> do
            let checkpoint step _ = when (step == BeforeLink) $ do
                  File.rename source saved
                  (if symlink then File.createSymbolicLink else File.createLink) other source
            (do
              expectUnavailable expected (acquirePinWith checkpoint owner source (Ascii.pack fixture.directory))
              closePin owner
              status <- File.getSymbolicLinkStatus source
              if symlink then assertBool "public symlink was removed" (File.isSymbolicLink status)
                else File.getSymbolicLinkStatus other >>= (identity status @?=) . identity)
              `finally` do
                File.removeLink source
                File.rename saved source
  , testCase "an existing alias is never claimed even when its inode matches" $
      withFixture $ \fixture -> bracket newPinOwner closePin $ \owner -> do
        reached <- newEmptyMVar
        let source = Ascii.pack fixture.socket
            checkpoint step directory = when (step == BeforeLink) $ do
              File.createLink source (directory <> "/s")
              putMVar reached directory
        try @PinError (acquirePinWith checkpoint owner source (Ascii.pack fixture.directory)) >>= \case
          Left (SocketPinUnavailable (FileSystemFailure cause)) ->
            assertBool "link did not fail with EEXIST" (isAlreadyExistsError cause)
          _ -> assertFailure "existing alias was accepted"
        directory <- takeMVar reached
        try @PinError (closePin owner) >>= \case
          Left (SocketPinCleanupFailed (FileSystemFailure _)) -> pure ()
          _ -> assertFailure "cleanup claimed the existing alias"
        existing <- File.getSymbolicLinkStatus (directory <> "/s")
        actual <- File.getSymbolicLinkStatus source
        identity existing @?= identity actual
        File.removeLink (directory <> "/s")
        closePin owner
        assertAbsent directory
  , testCase "cleanup retains unexpected children and can finish after correction" $
      withFixture $ \fixture -> bracket newPinOwner closePin $ \owner -> do
        pin <- acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        let directory = parentOf (pinPath pin)
            sentinel = directory <> "/sentinel"
        path <- decodePath sentinel
        Bytes.writeFile path "keep"
        try @PinError (closePin owner) >>= \case
          Left (SocketPinCleanupFailed _) -> pure ()
          _ -> assertFailure "unexpected child did not leave explicit cleanup debt"
        Bytes.readFile path >>= (@?= "keep")
        assertAbsent (pinPath pin)
        File.removeLink sentinel
        closePin owner
        closePin owner
        assertAbsent directory
        try @PinError (acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)) >>= \case
          Left PinAlreadyUsed -> pure ()
          _ -> assertFailure "closed owner accepted a new generation"
  , testCase "cleanup never deletes a replacement directory" $
      withFixture $ \fixture -> bracket newPinOwner closePin $ \owner -> do
        pin <- acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        let directory = parentOf (pinPath pin)
            moved = directory <> "-moved"
        File.rename directory moved
        Directory.createDirectory directory 0o700
        path <- decodePath (pinPath pin)
        Bytes.writeFile path "keep replacement"
        (do
          try @PinError (closePin owner) >>= \case
            Left (SocketPinCleanupFailed IdentityChanged) -> pure ()
            _ -> assertFailure "cleanup accepted a replacement directory"
          Bytes.readFile path >>= (@?= "keep replacement")) `finally` do
            File.removeLink (pinPath pin) `catch` \problem ->
              if isDoesNotExistError problem then pure () else throwIO problem
            Directory.removeDirectory directory `catch` \problem ->
              if isDoesNotExistError problem then pure () else throwIO problem
            File.rename moved directory
        closePin owner
  , testCase "cross-filesystem refusal preserves the cause and removes only owned names" $
      withFixture $ \fixture -> bracket (mkdtemp "/dev/shm/libtmux-haskell-") removeOwnedDirectory $ \parent -> do
        sourceStatus <- File.getSymbolicLinkStatus (Ascii.pack fixture.socket)
        parentStatus <- File.getSymbolicLinkStatus parent
        assertBool "test requires distinct /tmp and /dev/shm filesystems"
          (File.deviceID sourceStatus /= File.deviceID parentStatus)
        bracket newPinOwner closePin $ \owner -> do
          try @PinError (acquirePin owner (Ascii.pack fixture.socket) parent) >>= \case
            Left (SocketPinUnavailable (FileSystemFailure _)) -> pure ()
            _ -> assertFailure "cross-filesystem pin did not fail with its IO cause"
          closePin owner
        entries parent >>= (@?= [])
  ]

expectUnavailable :: PinReason -> IO a -> IO ()
expectUnavailable reason action = try @PinError action >>= \case
  Left (SocketPinUnavailable actual) -> actual @?= reason
  Left other -> assertFailure ("unexpected pin error: " <> show other)
  Right _ -> assertFailure ("pin admitted invalid input: " <> show reason)

identity :: File.FileStatus -> EndpointIdentity
identity status = EndpointIdentity (fromIntegral (File.deviceID status)) (fromIntegral (File.fileID status))

parentOf :: ByteString -> ByteString
parentOf path = Bytes.take (Bytes.length path - 2) path

decodePath :: ByteString -> IO FilePath
decodePath path = OsString.fromBytes path >>= OsPath.decodeFS

assertAbsent :: ByteString -> IO ()
assertAbsent path = try @IOException (File.getSymbolicLinkStatus path) >>= \case
  Left problem | isDoesNotExistError problem -> pure ()
  Left problem -> throwIO problem
  Right _ -> assertFailure "owned pin name remains"

entries :: ByteString -> IO [ByteString]
entries path = bracket (Directory.openDirStream path) Directory.closeDirStream $ \stream ->
  let readAll = Directory.readDirStream stream >>= \name ->
        if Bytes.null name then pure [] else do
          rest <- readAll
          pure (if name `elem` [".", ".."] then rest else name : rest)
  in sort <$> readAll

removeOwnedDirectory :: ByteString -> IO ()
removeOwnedDirectory path = decodePath path >>= removePathForcibly
