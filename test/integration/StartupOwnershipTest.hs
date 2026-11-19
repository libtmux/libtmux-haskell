-- | Physical startup evidence independent of the socket or startup receipt.
module StartupOwnershipTest (tests) where

import Control.Exception
import Control.Monad (forM_, (>=>))
import Data.ByteString qualified as Bytes
import Data.IORef
import LibTmux.Internal.OwnedServer qualified as OS
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import System.Directory (doesPathExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "physical startup ownership"
  [ testCase "a refused startup that physically exited keeps no unresolved birth" failedStartup ]

failedStartup :: Assertion
failedStartup = bracket (newIORef []) (readIORef >=> mapM_ N.close) $ \witnesses -> do
  names <- newIORef Nothing
  let record spec = do
        started <- N.launch spec
        case started of
          N.Refused _ -> pure ()
          N.Owned child -> do
            copy <- OS.cDup child.pidfd
            assertBool "independent child witness" (copy >= 0)
            modifyIORef' witnesses (copy :)
        pure started
      probe = OS.defaultProbe
        { OS.hooks = P.defaultHooks {P.launchNative = record}
        , OS.stage = \_ known -> writeIORef names (Just known) }
  outcome <- tryWithContext @SomeException (OS.withOwnedServerWith probe "/bin/false" (\_ -> assertFailure "false admitted"))
  observed <- readIORef witnesses
  assertBool "startup child witnessed" (not (null observed))
  forM_ observed $ \fd -> OS.awaitExit fd 0 >>= assertBool "child physically alive at completion"
  case outcome of
    Right _ -> assertFailure "false startup succeeded"
    Left (ExceptionWithContext context cause) -> do
      case fromException cause of
        Just (OS.StartFailed (Just (N.Exited 1)) _) -> pure ()
        _ -> assertFailure ("unexpected startup failure: " <> show cause)
      assertBool "the exited exact child still has unresolved startup ownership" (null (OS.ownedRecoveries context))
  paths <- readIORef names
  forM_ paths $ \known -> doesPathExist (showPath known.directory) >>= assertBool "private directory retained after exit" . not
  where
    showPath = map (toEnum . fromIntegral) . Bytes.unpack
