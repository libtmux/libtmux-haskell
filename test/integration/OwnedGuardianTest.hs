module OwnedGuardianTest (tests) where

import Control.Concurrent.Async (cancel, race, wait, withAsync)
import Control.Monad (unless, when)
import Control.Concurrent.STM
import Control.Exception
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import System.Exit (ExitCode (..))
import Data.IORef
import Data.Maybe (fromMaybe)
import Fixture qualified
import GuardianWitness qualified as W
import LibTmux.Capabilities qualified as Cap
import LibTmux.Program qualified as Program
import LibTmux.Internal.OwnedServer qualified as OS
import LibTmux.Internal.Runtime qualified as LibRuntime
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Guardian qualified as G
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Internal.Scope (CleanupStatus (..))
import Data.IntMap.Strict qualified as Map
import GHC.Conc (threadWaitRead)
import System.Posix.Types (Fd (..))
import System.Posix.Files.ByteString qualified as Files
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

witnessedFailure :: IO ()
witnessedFailure = do
  executable <- selectedExecutable
  W.withLauncher 1 executable $ \launcher server -> do
    started <- newEmptyTMVarIO
    continue <- newEmptyTMVarIO
    entered <- newIORef False
    let checkpoint OS.ClientLaunched _ = atomically (putTMVar started ()) >> atomically (readTMVar continue)
        checkpoint _ _ = pure ()
        action = tryWithContext @OS.OwnedError $
          OS.withOwnedServerWith OS.defaultProbe {OS.stage=checkpoint} launcher (\_ -> writeIORef entered True)
    withAsync action $ \scope -> do
      atomically (readTMVar started)
      W.withWitness server $ \(witness,_) -> do
        N.pidReady witness >>= (@?= False)
        atomically (putTMVar continue ())
        wait scope >>= \case
          Left (ExceptionWithContext context (OS.StartFailed _ _)) ->
            assertBool "completed cleanup retained an owner" (null (OS.ownedRecoveries context))
          other -> assertFailure (show other)
        N.pidReady witness >>= (@?= True)
        readIORef entered >>= (@?= False)

witnessedSuccess :: Int -> IO ()
witnessedSuccess mode = do
  executable <- selectedExecutable
  W.withLauncher mode executable $ \launcher server -> do
    ready <- newEmptyTMVarIO
    finish <- newEmptyTMVarIO
    let config=Server.defaultOwnedServerConfig {Server.tmuxExecutable=Os.fromBytestring launcher}
        action=Server.withOwnedServer config $ \owned -> do
          snapshot <- Server.capture owned
          when (mode==3 && Cap.supports (Server.serverCapabilities owned) Cap.ManagedPrograms) $ do
            result <- Server.runProgram owned (Program.programOptions (Os.fromBytestring "/bin/true") [])
            result.programExit @?= Program.ProgramExited 0
          atomically (putTMVar ready (Snapshot.serverInfo snapshot).pid)
          atomically (readTMVar finish)
    W.withCollected server $ \collected -> withAsync action $ \scope -> do
      pid <- race (wait scope) (atomically (readTMVar ready)) >>= \case
        Left () -> fail "private callback did not publish readiness"
        Right value -> pure value
      bracket (N.openPid (fromInteger pid)) N.close $ \daemon -> do
        witnesses <- collected
        assertBool "no independent launcher child" (not (null witnesses))
        when (mode==3) (assertBool "ordinary native clients produced no independent descendants" (length witnesses>=6))
        -- A Program may already have retired descendants in its own group.
        -- The first startup witness must remain live until the outer scope.
        case reverse witnesses of
          first:_ -> N.pidReady first >>= (@?= False)
          [] -> assertFailure "no startup witness"
        atomically (putTMVar finish ())
        wait scope
        mapM_ (\fd -> N.pidReady fd >>= (@?= True)) (daemon:witnesses)

unpublished :: Bool -> IO ()
unpublished loseHelper = do
  executable <- selectedExecutable
  W.withLauncher 1 executable $ \launcher server -> do
    budget <- B.newBudget (P.inspectionBytes+G.transportBytes)
    domain <- G.prepareDomain budget P.normalFork
    G.startDomain domain
    pin <- Pin.newPinOwner
    pool <- P.newPool budget P.normalFork pin 16
    reached <- newEmptyTMVarIO
    continue <- newEmptyTMVarIO
    let base=G.backend domain
        selected=base {P.prepareBackend= \allocation spec -> do
          prepared <- base.prepareBackend allocation spec
          pure prepared {P.startPrepared=do
            _ <- prepared.startPrepared
            -- Collection has happened, but publication to the pool has not.
            entries <- Map.elems <$> readTVarIO domain.entries
            case entries of
              [entry] -> atomically (readTMVar entry.status) >>= \case
                Right (N.Exited 0) -> pure ()
                other -> assertFailure (show other)
              _ -> assertFailure "unpublished request registry changed"
            atomically (putTMVar reached ())
            atomically (readTMVar continue)
            throwIO (userError "unpublished marker")}}
    atomically (P.bindBackend pool selected)
    ticket <- P.submit B.Ordinary P.defaultHooks pool (N.spec launcher [launcher,"-D"]) ""
    failure <- newTVarIO Nothing
    let cleanup=unless loseHelper $ do
          released <- G.isReleased domain
          unless released $ do
            G.requestStop domain
            G.awaitStopped domain
            _ <- P.requestClose pool
            count <- atomically (P.activeCount pool)
            when (count==0) (P.awaitCleanup pool >> G.releaseDomain domain)
    P.preservingFinally failure (do
      atomically (readTMVar reached)
      W.withWitness server $ \(witness,_) -> do
        N.pidReady witness >>= (@?= False)
        (_,helper) <- G.nativeDescriptors domain
        when loseHelper $ do
          N.cSignal helper 9 >>= (@?= 0)
          threadWaitRead (Fd helper)
          -- Fixture collection cannot supply the missing subtree verdict.
          N.waitChild (N.Child helper (-1) (-1) (-1) N.ParentStatus) >>= \case
            Just (N.Signaled 9 False) -> pure ()
            other -> assertFailure (show other)
        atomically (putTMVar continue ())
        try @IOException (P.await ticket) >>= \case
          Left problem -> displayException problem @?= "user error (unpublished marker)"
          Right _ -> assertFailure "unpublished primary exception disappeared"
        atomically $ do
          retired <- P.ticketRetired pool ticket
          busy <- readTVar ticket.busy
          check (retired || not busy)
        atomically (P.activeCount pool) >>= (@?= if loseHelper then 1 else 0)
        usage <- atomically (B.usage budget)
        usage.children @?= if loseHelper then 2 else 1
        if loseHelper then do
          W.cRetire witness >>= W.checked
          N.pidReady witness >>= (@?= True)
          _ <- P.requestClose pool
          atomically (P.activeCount pool) >>= (@?= 1)
          G.isReleased domain >>= (@?= False)
          readTVarIO domain.full >>= (@?= False)
        else do
          N.pidReady witness >>= (@?= False)
          cleanup
          N.pidReady witness >>= (@?= True)) cleanup

cancelClient :: IO ()
cancelClient = do
  executable <- selectedExecutable
  OS.withOwnedServer executable $ \owned -> do
    let pool=owned.owner.scope
    entry <- case pool of Just (_,value) -> pure value; _ -> fail "missing scope"
    let nativePool=LibRuntime.serverOwnerPool entry
    ticket <- P.submitInputRegistered (const (pure ())) B.Ordinary P.defaultHooks nativePool (N.spec "/bin/cat" ["/bin/cat"]) P.KeepInputOpen
    pid <- P.clientProcessId ticket
    bracket (N.openPid (fromInteger pid)) N.close $ \witness -> do
      withAsync (P.await ticket) $ \observer -> cancel observer
      N.pidReady witness >>= (@?= False)
      atomically (P.ticketOwned nativePool ticket) >>= (@?= True)
      P.abort ticket
      try @P.OwnerError (P.await ticket) >>= \case
        Left P.Aborted -> pure ()
        other -> assertFailure (show other)
      atomically (P.ticketRetired nativePool ticket >>= check)
      N.pidReady witness >>= (@?= True)
      descriptor <- readIORef owned.owner.held >>= maybe (fail "daemon descriptor lost") pure . (.pidfd)
      OS.verifyPinned OS.defaultProbe owned.runtime owned.handle executable descriptor >>= (@?= owned.daemonPid)

replacement :: IO ()
replacement = Fixture.withFixture $ \fixture -> do
  executable <- selectedExecutable
  placed <- newIORef Nothing
  injected <- newIORef False
  witness <- newIORef Nothing
  let borrowed=Bytes.pack fixture.socket
      stage OS.DaemonOwned names=writeIORef placed (Just names)
      stage _ _=pure ()
      phase OS.PhaseNames=do
        done <- readIORef injected
        unless done $ do
          names <- readIORef placed >>= maybe (fail "private names not journaled") pure
          OS.ignoreMissing (Files.removeLink names.socket)
          Files.createLink borrowed names.socket
          writeIORef injected True
      phase _=pure ()
  before <- OS.statusIfPresent borrowed
  outcome <- tryWithContext @OS.OwnedError $
    OS.withOwnedServerWith OS.defaultProbe {OS.stage=stage,OS.phase=phase} executable $ \owned ->
      N.openPid (fromInteger owned.daemonPid) >>= writeIORef witness . Just
  case outcome of
    Left (ExceptionWithContext context (OS.CleanupPending _)) -> case OS.ownedRecoveries context of
      recovery:_ -> do
        let owner=OS.recoveryOwner recovery
        OS.observeOwned owner >>= \status -> status.complete @?= False
        readTVarIO owner.domain.full >>= (@?= True)
        G.isReleased owner.domain >>= (@?= False)
        names <- readIORef placed >>= maybe (fail "private names lost") pure
        same <- OS.statusIfPresent names.socket
        fmap OS.identity same @?= fmap OS.identity before
        Files.removeLink names.socket
        OS.settle owner
        OS.observeOwned owner >>= \status -> status.complete @?= True
      [] -> assertFailure "replacement lost its cleanup owner"
    _ -> assertFailure "replacement was removed or not reported"
  readIORef witness >>= mapM_ (\fd -> (N.pidReady fd >>= (@?= True)) `finally` N.close fd)
  after <- OS.statusIfPresent borrowed
  fmap OS.identity after @?= fmap OS.identity before

sequentialPrograms :: IO ()
sequentialPrograms = do
  executable <- selectedExecutable
  W.withLauncher 2 executable $ \application server -> do
    config <- configuration
    Server.withOwnedServer config $ \owned ->
      if Cap.supports (Server.serverCapabilities owned) Cap.ManagedPrograms
        then Server.withProgram owned (Program.programOptions (Os.fromBytestring application) [Os.fromBytestring "--application"]) $ \_ ->
          W.withWitness server $ \(bystander,_) -> do
            N.pidReady bystander >>= (@?= False)
            first <- Server.runProgram owned (Program.programOptions (Os.fromBytestring "/bin/true") [])
            first.programExit @?= Program.ProgramExited 0
            N.pidReady bystander >>= (@?= False)
            second <- Server.runProgram owned (Program.programOptions (Os.fromBytestring "/bin/true") [])
            second.programExit @?= Program.ProgramExited 0
            N.pidReady bystander >>= (@?= False)
            _ <- Server.capture owned
            pure ()
        else try @Cap.CapabilityError (Server.runProgram owned (Program.programOptions (Os.fromBytestring "/bin/true") [])) >>= \case
          Left (Cap.CapabilityUnavailable Cap.ManagedPrograms _) -> pure ()
          _ -> assertFailure "unsupported daemon admitted Program"

relatedIdentity :: IO ()
relatedIdentity = do
  budget <- B.newBudget P.inspectionBytes
  first <- LibRuntime.newRuntimeUsing budget P.normalFork Nothing False
  second <- LibRuntime.newRuntimeUsing budget P.normalFork Nothing False
  owner <- LibRuntime.newServerOwner first
  try @LibRuntime.ReadError (atomically (LibRuntime.inspectServerOwner second owner)) >>= \case
    Left LibRuntime.ForeignServer -> pure ()
    other -> assertFailure ("shared capacity admitted a foreign owner: "<>show other)
  _ <- LibRuntime.shutdown first
  observed <- atomically (LibRuntime.inspectServerOwner first owner)
  assertBool "retired owner changed its runtime identity" (null observed.pending)
  current <- atomically (LibRuntime.usage second)
  current.accepting @?= True
  _ <- LibRuntime.shutdown second
  pure ()

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
  , testCase "parent exit before listen accounts for its independently witnessed child" $
      W.isolated "parent exit before listen accounts for its independently witnessed child" witnessedFailure
  , testCase "matching foreground listener also retires its independently witnessed extra child" $
      W.isolated "matching foreground listener also retires its independently witnessed extra child" (witnessedSuccess 2)
  , testCase "later native and Program clients remain inside the same descendant domain" $
      W.isolated "later native and Program clients remain inside the same descendant domain" (witnessedSuccess 3)
  , testCase "unpublished collected primary releases its request without ending the domain" $
      W.isolated "unpublished collected primary releases its request without ending the domain" (unpublished False)
  , testCase "guardian loss retains unpublished debt even after independently known child exit" $
      W.isolated "guardian loss retains unpublished debt even after independently known child exit" (unpublished True)
  , testCase "cancelled client observer keeps ownership and client abort preserves daemon readiness" cancelClient
  , testCase "foreign socket replacement survives while terminal guardian ownership is retained" replacement
  , testCase "sequential Programs preserve a live independent bystander and parent admission" $
      W.isolated "sequential Programs preserve a live independent bystander and parent admission" sequentialPrograms
  , testCase "shared capacity does not grant authority over a related runtime owner" relatedIdentity
  ]
