module OwnedGuardianTest (tests) where

import Control.Exception
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import System.Exit (ExitCode (..))
import Data.IORef
import Data.Maybe (fromMaybe)
import Fixture qualified
import LibTmux.Internal.OwnedServer qualified as OS
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Server qualified as Server
import LibTmux.Snapshot qualified as Snapshot
import System.Environment (lookupEnv)
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

selectedExecutable :: IO Bytes.ByteString
selectedExecutable = Bytes.pack . fromMaybe "tmux" <$> lookupEnv "LIBTMUX_TEST_TMUX"

configuration :: IO Server.OwnedServerConfig
configuration = do
  executable <- selectedExecutable
  pure Server.defaultOwnedServerConfig {Server.tmuxExecutable=Os.fromBytestring executable}

tests :: TestTree
tests = testGroup "private guardian scope"
  [ testCase "empty native startup retires the exact daemon and closes its generation" $ do
      config <- configuration
      retained <- newIORef Nothing
      witness <- Server.withOwnedServer config $ \server -> do
        snapshot <- Server.capture server
        Snapshot.sessions snapshot @?= []
        Snapshot.windows snapshot @?= []
        Snapshot.panes snapshot @?= []
        let info=Snapshot.serverInfo snapshot
        descriptor <- N.openPid (fromInteger info.pid)
        N.pidReady descriptor >>= (@?= False)
        writeIORef retained (Just server)
        pure descriptor
      (N.pidReady witness >>= (@?= True)) `finally` N.close witness
      readIORef retained >>= \case
        Nothing -> assertFailure "no admitted generation"
        Just server -> try @Server.TmuxException (Server.capture server) >>= \case
          Left Server.ServerClosed -> pure ()
          other -> assertFailure (show other)
  , testCase "callback exception and caller masking state survive complete cleanup" $ do
      config <- configuration
      let action = Server.withOwnedServer config $ \_ -> do
            getMaskingState >>= (@?= Unmasked)
            throwIO (userError "callback marker")
      tryWithContext @IOException action >>= \case
        Left (ExceptionWithContext _ problem) -> displayException problem @?= "user error (callback marker)"
        Right () -> assertFailure "callback exception was lost"
  , testCase "borrowed daemon and socket survive private scope retirement" $
      Fixture.withFixture $ \fixture -> do
        let borrowed=Bytes.pack fixture.socket
        before <- OS.statusIfPresent borrowed
        config <- configuration
        Server.withOwnedServer config (\server -> Server.capture server >>= \snapshot -> Snapshot.sessions snapshot @?= [])
        after <- OS.statusIfPresent borrowed
        fmap OS.identity before @?= fmap OS.identity after
        Fixture.command fixture ["display-message", "-p", "#{pid}"] >>= \(code,reply,errors) -> do
          code @?= ExitSuccess
          errors @?= ""
          assertBool "borrowed daemon stopped responding" (not (Lazy.null reply))
  ]
