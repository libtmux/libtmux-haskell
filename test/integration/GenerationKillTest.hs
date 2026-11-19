module GenerationKillTest (tests) where

import Control.Concurrent.Async (AsyncCancelled (..), cancel, wait, withAsync)
import Control.Concurrent.STM
import Control.Exception hiding (handle)
import Control.Monad (when)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Fixture qualified
import GHC.Conc (threadWaitRead)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import LibTmux.Internal.OwnedServer qualified as OS
import LibTmux.Internal.ControlFrames qualified as ControlFrames
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope (CleanupStatus (..))
import LibTmux.Internal.SocketPin (pinPath)
import System.Directory (doesPathExist)
import System.FilePath (takeDirectory)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os
import System.Posix.Files.ByteString qualified as Files
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Signals (sigUSR1)
import System.Posix.Types (Fd (..))
import System.Process.Typed (nullStream, proc, readProcess, setStdin)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture=(Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable=Os.fromBytestring (Bytes.pack fixture.executable)}

withWitness :: Tmux.Server -> (Int -> IO a) -> IO a
withWitness server action = do
  snapshot <- Tmux.capture server
  bracket (N.openPid (fromInteger (Tmux.serverInfo snapshot).pid)) N.close (action . fromIntegral)

closed :: IO a -> IO ()
closed action = try @Tmux.TmuxException action >>= \case
  Left Tmux.ServerClosed -> pure ()
  _ -> assertFailure "retired Server admitted an operation"

owned :: IO ()
owned = Fixture.withFixture $ \fixture -> do
  let settings=Tmux.defaultOwnedServerConfig {Tmux.tmuxExecutable=Os.fromBytestring (Bytes.pack fixture.executable)}
      options=Creation.defaultSessionOptions {Creation.process=Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])}
  directory <- Tmux.withOwnedServer settings $ \server -> do
    snapshot <- Tmux.capture server
    socket <- Path.decodeFS (Tmux.serverInfo snapshot).socketPath
    created <- Tmux.createSession server options
    withWitness server $ \daemon -> do
      let target=Text.unpack (Tmux.renderPaneId (Tmux.paneId created.pane))
      (code,output,errors) <- readProcess $ setStdin nullStream $ proc fixture.executable
        ["-N","-S",socket,"display-message","-p","-t",target,"#{pane_pid}"]
      (code,errors) @?= (ExitSuccess,"")
      pid <- case reads (Lazy.unpack output) of [(value,"\n")] -> pure value; _ -> fail "invalid owned pane PID"
      bracket (N.openPid pid) N.close $ \pane -> do
        N.pidReady pane >>= (@?= False)
        Tmux.killServer server
        N.pidReady (fromIntegral daemon) >>= (@?= True)
        N.pidReady pane >>= (@?= True)
        closed (Tmux.capture server)
        closed (Tmux.killServer server)
    pure (takeDirectory socket)
  doesPathExist directory >>= (@?= False)

borrowed :: IO ()
borrowed = Fixture.withFixture $ \fixture -> do
  retained <- Tmux.withServer (config fixture) pure
  closed (Tmux.killServer retained)
  Tmux.withServer (config fixture) $ \server -> withWitness server $ \daemon -> do
    N.pidReady (fromIntegral daemon) >>= (@?= False)
    Tmux.killServer server
    N.pidReady (fromIntegral daemon) >>= (@?= True)
    closed (Tmux.capture server)

siblings :: IO ()
siblings = Fixture.withFixture $ \first -> Fixture.withFixture $ \second ->
  Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime (config first) $ \a ->
    Tmux.withServerIn runtime (config second) $ \b ->
      withWitness a $ \daemonA -> withWitness b $ \daemonB -> do
        before <- OS.statusIfPresent (Bytes.pack second.socket)
        Tmux.killServer a
        N.pidReady (fromIntegral daemonA) >>= (@?= True)
        N.pidReady (fromIntegral daemonB) >>= (@?= False)
        _ <- Tmux.capture b
        after <- OS.statusIfPresent (Bytes.pack second.socket)
        fmap OS.identity before @?= fmap OS.identity after

replacedPath :: IO ()
replacedPath = Fixture.withFixture $ \first -> Fixture.withFixture $ \second ->
  Tmux.withServer (config first) $ \a -> Tmux.withServer (config second) $ \b ->
    withWitness a $ \daemonA -> withWitness b $ \daemonB -> do
      let source=Bytes.pack first.socket
          replacement=Bytes.pack second.socket
      original <- OS.statusIfPresent replacement
      Files.removeLink source
      Files.createLink replacement source
      Tmux.killServer a
      N.pidReady (fromIntegral daemonA) >>= (@?= True)
      N.pidReady (fromIntegral daemonB) >>= (@?= False)
      after <- OS.statusIfPresent source
      fmap OS.identity after @?= fmap OS.identity original
      _ <- Tmux.capture b
      pure ()

rebound :: IO ()
rebound = Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server ->
  withWitness server $ \daemon -> Fixture.withClient fixture (Fixture.Pipe,Fixture.Pipe,Fixture.Pipe)
    ["-u","-N","-S",fixture.socket,"-C","attach-session","-t","fixture"] $ \control -> do
      decoder <- newIORef ControlFrames.newDecoder
      let reply = Fixture.readSome control.output >>= \case
            Nothing -> fail "control connection ended before its completion reply"
            Just bytes -> do
              current <- readIORef decoder
              (next,frames) <- either (fail . show) pure (ControlFrames.feed current bytes)
              writeIORef decoder next
              when (any rejected frames) (fail "control completion command was rejected")
              if any succeeded frames then pure () else reply
          succeeded (ControlFrames.Reply ControlFrames.ReplySucceeded _) = True
          succeeded _ = False
          rejected (ControlFrames.Reply ControlFrames.ReplyRejected _) = True
          rejected (ControlFrames.Exit _) = True
          rejected _ = False
      reply
      let socket=Bytes.pack fixture.socket
      original <- OS.statusIfPresent socket
      bracket (Bytes.useAsCString (Bytes.pack fixture.directory) OS.cWatchStart >>= \fd ->
        if fd<0 then N.raise (negate fd) else pure fd) N.close $ \watch -> do
          Files.removeLink socket
          N.cSignal (fromIntegral daemon) sigUSR1 >>= (@?= 0)
          let changed=OS.statusIfPresent socket >>= \current ->
                if fmap OS.identity current/=fmap OS.identity original && maybe False (const True) current
                  then pure ()
                  else threadWaitRead (Fd watch) >> OS.cWatchDrain watch >>= \rc ->
                    if rc<0 then N.raise (negate rc) else changed
          changed
      -- The new inode proves the signal handler has begun. A matched reply on
      -- this pre-existing connection proves it returned and closed the old listener.
      let command="display-message -p libtmux-rebind-complete\n"
      count <- Posix.fdWrite control.input command
      fromIntegral count @?= Bytes.length command
      reply
      Tmux.tryTmux (Tmux.killServer server) >>= \case
        Left (ExceptionWithContext _ (Tmux.OperationFailed _)) -> pure ()
        _ -> assertFailure "rebound generation authorized termination"
      N.pidReady (fromIntegral daemon) >>= (@?= False)
      Fixture.command fixture ["display-message","-p","#{pid}"] >>= \(code,_,errors) ->
        (code,errors) @?= (ExitSuccess,"")

cancelledKill :: IO ()
cancelledKill = Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
  handle <- R.adopt runtime (Bytes.pack fixture.socket) (Bytes.pack fixture.directory)
  reached <- newEmptyTMVarIO
  release <- newEmptyTMVarIO
  first <- newIORef True
  let deliver fd number = do
        pause <- atomicModifyIORef' first (\value -> (False,value))
        when pause $ atomically (putTMVar reached ()) >> atomically (readTMVar release)
        N.cSignal fd number
      probe=OS.defaultProbe {OS.signal=deliver}
  OS.withKillCapability probe (Bytes.pack fixture.executable) runtime handle $ \case
    Left problem -> throwIO problem
    Right capability -> flip finally (atomically (tryPutTMVar release ()) >> pure ()) $ do
      independent <- OS.peerPidfd (pinPath (R.serverPin handle)) >>= either N.raise pure
      flip finally (N.close independent) $ withAsync (tryWithContext @SomeException
        (OS.killAdoptedIf (OS.admissionOpen handle) capability)) $ \observer -> do
          atomically (readTMVar reached)
          cancel observer
          result <- wait observer
          context <- case result of
            Left (ExceptionWithContext context problem) -> do
              fromException @AsyncCancelled problem @?= Just AsyncCancelled
              pure context
            _ -> assertFailure "cancelled kill observer lost its exception"
          recovery <- case OS.ownedRecoveries context of
            [value] -> pure value
            _ -> fail "cancelled kill lost its unique owner"
          OS.observeOwned (OS.recoveryOwner recovery) >>= \status -> status.complete @?= False
          N.pidReady independent >>= (@?= False)
          atomically (putTMVar release ())
          OS.settle (OS.recoveryOwner recovery)
          N.pidReady independent >>= (@?= True)

tests :: TestTree
tests = testGroup "generation-bound daemon retirement"
  [ testCase "owned explicit kill retires daemon and pane before returning" owned
  , testCase "borrowed observation preserves daemon until explicit kill" borrowed
  , testCase "selected handle kill preserves a live sibling and socket" siblings
  , testCase "replacement source path cannot retarget the held capability" replacedPath
  , testCase "rebound original listener refuses kill and preserves its process" rebound
  , testCase "cancelled kill observer retains the authorized physical request" cancelledKill
  ]
