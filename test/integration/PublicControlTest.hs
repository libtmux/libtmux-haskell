module PublicControlTest (tests) where

import Control.Concurrent (ThreadId, yield)
import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, void)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import Foreign.C.Types (CInt)
import GHC.Conc (BlockReason (..), ThreadStatus (..), threadStatus, threadWaitRead, threadWaitReadSTM)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import LibTmux.Recovery qualified as Recovery
import LibTmux.Internal.Control qualified as Control
import LibTmux.Internal.Process qualified as Process
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as Runtime
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin qualified as Pin
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.OsString.Posix qualified as Os
import System.Posix.IO (dup)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
import Text.Read (readMaybe)

tests :: TestTree
tests = testGroup "public control notifications"
  [ testCase "observes a rename and retires the client without closing the daemon" $
      withServer $ \fixture server session window -> withWitness $ \remember -> do
        before <- native fixture ["list-sessions", "-F", "#{session_id}"]
        control <- Tmux.withControl server session Tmux.defaultControlOptions $ \stream -> do
          _ <- remember (clientWitness fixture)
          Tmux.renameWindow server window "stream rename"
          seen <- bounded (awaitRename stream)
          seen @?= (Tmux.windowId window, "stream rename")
          pure stream
        atomically (Tmux.pollControlEvent control) >>= \result ->
          assertBool "scope did not close its stream" (result == Just (Left Tmux.ControlClosed))
        native fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= "")
        native fixture ["list-sessions", "-F", "#{session_id}"] >>= (@?= before)

  , testCase "can include native pane output notifications" $
      withServer $ \fixture server session _ -> do
        graph <- Tmux.capture server
        pane <- case Tmux.panes graph of
          [only] -> pure only
          _ -> fail "expected the fixture pane"
        let options = Tmux.defaultControlOptions {Tmux.includePaneOutput = True}
            geometry = native fixture ["display-message", "-p", "-t", "%0",
              "#{window_width} #{window_height} #{pane_width} #{pane_height}"]
        original <- geometry
        Tmux.withControl server session options $ \stream -> do
          geometry >>= (@?= original)
          Tmux.sendKeys server pane.ref (Tmux.LiteralText "pane-stream")
          Tmux.sendKeys server pane.ref (Tmux.NamedKeys ("Enter" :| []))
          bounded (awaitPaneOutput stream (Tmux.paneId pane.ref))

  , testCase "a full queue preserves its first event and reports overflow" $
      withServer $ \fixture server session window -> withWitness $ \remember -> do
        let options = Tmux.defaultControlOptions {Tmux.eventCapacity = 1}
        Tmux.withControl server session options $ \stream -> do
          fd <- remember (clientWitness fixture)
          forM_ ["first", "second", "third"] $ \label ->
            Tmux.renameWindow server window label
          bounded (threadWaitRead (Fd fd))
          first <- bounded (awaitRename stream)
          first @?= (Tmux.windowId window, "first")
          bounded (atomically (Tmux.readControlEvent stream)) >>= \result ->
            assertBool "overflow was lost" (result == Left Tmux.ControlOverflow)
        native fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= "")
        native fixture ["list-sessions", "-F", "#{session_name}"] >>= (@?= "fixture\n")

  , testCase "daemon exit ends the stream and retires its reader" $
      withServer $ \fixture server session _ -> withWitness $ \remember ->
        Tmux.withControl server session Tmux.defaultControlOptions $ \stream -> do
          _ <- remember (clientWitness fixture)
          _ <- native fixture ["kill-server"]
          bounded (awaitEnd stream) >>= \case
            Tmux.ControlExited _ -> pure ()
            other -> assertFailure ("unexpected terminal result " <> show other)

  , testCase "cancelling a blocked STM consumer preserves cancellation and reaps its client" $
      withServer $ \fixture server session _ -> withWitness $ \remember -> do
        ready <- newEmptyTMVarIO
        let run = Tmux.withControl server session Tmux.defaultControlOptions $ \stream -> do
              _ <- remember (clientWitness fixture)
              atomically (putTMVar ready ())
              _ <- awaitEnd stream
              assertFailure "control stream ended before cancellation"
        withAsync (tryWithContext @SomeException run) $ \worker -> do
          bounded (atomically (takeTMVar ready))
          bounded (awaitBlocked (asyncThreadId worker))
          throwTo (asyncThreadId worker) ThreadKilled
          bounded (wait worker) >>= \case
            Left (ExceptionWithContext _ problem) -> fromException problem @?= Just ThreadKilled
            Right _ -> assertFailure "scope swallowed cancellation"
        native fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= "")
        native fixture ["list-sessions", "-F", "#{session_name}"] >>= (@?= "fixture\n")

  , testCase "state wait recognizes the initially active pane through its exact slot" $
      withServer $ \_ server session _ -> do
        (slot, pane) <- stateTarget server session
        seen <- Tmux.waitForPaneState server slot pane Tmux.PaneActive Tmux.defaultPaneStateWait
        fresh <- matchedState seen
        observed <- either (fail . show) pure (Tmux.lookupPane fresh pane)
        assertBool "matched snapshot must show the active pane" observed.active

  , testCase "state wait sees native pane death without terminal output" $
      withServer $ \fixture server session _ -> withWitness $ \remember -> do
        (slot, pane) <- stateTarget server session
        let options = Tmux.defaultPaneStateWait {Tmux.stateTimeout = 0.8}
        void (native fixture ["set-option", "-p", "-t", paneTarget pane, "remain-on-exit", "on"])
        signalAttachment fixture session
        withAsync (Tmux.waitForPaneState server slot pane Tmux.PaneDead options) $ \worker -> do
          awaitAttachment fixture
          _ <- remember (clientWitness fixture)
          Tmux.sendKeys server pane (Tmux.NamedKeys ("C-d" :| []))
          fresh <- bounded (wait worker) >>= matchedState
          observed <- either (fail . show) pure (Tmux.lookupPane fresh pane)
          assertBool "matched snapshot must show a dead pane" observed.dead
        native fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= "")

  , testCase "state wait observes a pane removed during observer registration" $
      withServer $ \fixture server session _ -> do
        (slot, bystander) <- stateTarget server session
        void (native fixture ["split-window", "-d", "exec /bin/cat -"])
        graph <- Tmux.capture server
        case filter ((/= bystander) . (.ref)) (Tmux.panes graph) of
          [target] -> do
            void (native fixture ["set-hook", "client-attached", "kill-pane -t " <> paneTarget target.ref])
            seen <- Tmux.waitForPaneState server slot target.ref Tmux.PaneAbsent Tmux.defaultPaneStateWait
            fresh <- matchedState seen
            map (.ref) (Tmux.panes fresh) @?= [bystander]
          _ -> assertFailure "expected one extra pane in the fixture"

  , testCase "state wait retains its latest snapshot at the deadline" $
      withServer $ \_ server session _ -> do
        (slot, pane) <- stateTarget server session
        let short = Tmux.defaultPaneStateWait {Tmux.stateTimeout = 0.12}
        Tmux.waitForPaneState server slot pane Tmux.PaneDead short >>= \case
          Tmux.PaneStateTimedOut (Just _) recovery -> settleRead server recovery
          _ -> assertFailure "state wait did not retain its snapshot on timeout"

  , testCase "state wait distinguishes a daemon lost while acquiring the graph" $
      withServer $ \fixture server session _ -> do
        (slot, pane) <- stateTarget server session
        signalAttachment fixture session
        withAsync (Tmux.waitForPaneState server slot pane Tmux.PaneDead Tmux.defaultPaneStateWait) $ \worker -> do
          awaitAttachment fixture
          void (native fixture ["kill-server"])
          bounded (wait worker) >>= \case
            Tmux.PaneStateDaemonLost _ recovery -> settleRead server recovery
            _ -> assertFailure "state wait did not report loss of the pinned daemon"

  , testCase "state wait uses the selected link in the requested session" $
      withServer $ \fixture server session window -> do
        (sourceSlot, pane) <- stateTarget server session
        other <- stateSession server
        idx <- either (fail . show) pure (Tmux.mkWindowIndex 4)
        let slot = Tmux.WindowSlot other.session idx
            short = Tmux.defaultPaneStateWait {Tmux.stateTimeout = 0.12}
        Tmux.linkWindow server sourceSlot slot
        Tmux.waitForPaneState server slot pane Tmux.PaneActive short >>= \case
          Tmux.PaneStateTimedOut (Just _) recovery -> settleRead server recovery
          _ -> assertFailure "a pane active through another session matched this unselected link"
        signalAttachment fixture other.session
        withAsync (Tmux.waitForPaneState server slot pane Tmux.PaneActive Tmux.defaultPaneStateWait) $ \worker -> do
          awaitAttachment fixture
          Tmux.selectWindowLink server slot
          fresh <- bounded (wait worker) >>= matchedState
          links <- either (fail . show) pure (Tmux.linksForSession fresh other.session)
          [(link.index, link.window) | link <- links, link.active] @?= [(idx, window)]

  , testCase "state wait notices a quiet removal outside its observer session" $
      withServer $ \fixture server session _ -> do
        (observer, bystander) <- stateTarget server session
        other <- stateSession server
        let remote = Tmux.WindowSlot other.session other.windowIndex
            short = Tmux.defaultPaneStateWait {Tmux.stateTimeout = 0.8}
        split <- Tmux.splitPane server remote other.pane
          Creation.defaultSplitOptions {Creation.splitProcess = Creation.ShellCommand "exec /bin/cat -"}
        signalAttachment fixture session
        withAsync (Tmux.waitForPaneState server observer split.pane Tmux.PaneAbsent short) $ \worker -> do
          awaitAttachment fixture
          Tmux.killPane server split.pane
          fresh <- bounded (wait worker) >>= matchedState
          Tmux.lookupPane fresh split.pane @?= Left (Tmux.MissingPane split.pane)
          _ <- either (fail . show) pure (Tmux.lookupPane fresh bystander)
          pure ()

  , testCase "state wait reports overflow and retires its observer" $
      withServer $ \fixture server session _ -> withWitness $ \remember -> do
        (_, pane) <- stateTarget server session
        empty <- either (fail . show) pure (Tmux.mkWindowIndex 9)
        let slot = Tmux.WindowSlot session empty
            options = Tmux.defaultPaneStateWait {Tmux.stateEventCapacity = 1}
            burst = intercalate [";"] [["rename-window", "burst-" <> show serial] | serial <- [1 .. 48 :: Int]]
        signalAttachment fixture session
        withAsync (Tmux.waitForPaneState server slot pane Tmux.PaneActive options) $ \worker -> do
          awaitAttachment fixture
          _ <- remember (clientWitness fixture)
          void (native fixture burst)
          bounded (wait worker) >>= \case
            Tmux.PaneStateObserverEnded Tmux.ControlOverflow (Just _) -> pure ()
            _ -> assertFailure "expected explicit control overflow"
        native fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= "")

  , testCase "state wait cancellation preserves ThreadKilled and reaps the observer" $
      withServer $ \fixture server session _ -> withWitness $ \remember -> do
        (_, pane) <- stateTarget server session
        empty <- either (fail . show) pure (Tmux.mkWindowIndex 9)
        let run = Tmux.waitForPaneState server (Tmux.WindowSlot session empty) pane
              Tmux.PaneActive Tmux.defaultPaneStateWait
        signalAttachment fixture session
        withAsync (tryWithContext @SomeException run) $ \worker -> do
          awaitAttachment fixture
          _ <- remember (clientWitness fixture)
          bounded (awaitBlocked (asyncThreadId worker))
          throwTo (asyncThreadId worker) ThreadKilled
          bounded (wait worker) >>= \case
            Left (ExceptionWithContext context problem) -> do
              fromException problem @?= Just ThreadKilled
              mapM_ (settleRead server . Just) (Recovery.captureRecoveries context)
            Right _ -> assertFailure "state wait swallowed cancellation"
        native fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= "")

  , testCase "state wait cancellation preserves an in-flight read" $
      withServer $ \fixture server session _ -> withWitness $ \remember -> do
        (_, pane) <- stateTarget server session
        empty <- either (fail . show) pure (Tmux.mkWindowIndex 9)
        let gate = "set-hook -g after-display-message { wait-for -S pane-state-reading ; wait-for pane-state-release }"
            run = Tmux.waitForPaneState server (Tmux.WindowSlot session empty) pane
              Tmux.PaneActive Tmux.defaultPaneStateWait
            releaseRead = do
              void (native fixture ["set-hook", "-gu", "after-display-message"])
              void (native fixture ["wait-for", "-S", "pane-state-release"])
        void (native fixture ["set-hook", "-t", sessionTarget session, "client-attached", gate])
        flip finally releaseRead $
          withAsync (tryWithContext @SomeException run) $ \worker -> do
            void (bounded (native fixture ["wait-for", "pane-state-reading"]))
            _ <- remember (clientWitness fixture)
            throwTo (asyncThreadId worker) ThreadKilled
            bounded (wait worker) >>= \case
              Left (ExceptionWithContext context problem) -> do
                fromException problem @?= Just ThreadKilled
                case Recovery.captureRecoveries context of
                  [owner] -> settleRead server (Just owner)
                  _ -> assertFailure "cancelled graph read lost its recovery"
              Right _ -> assertFailure "state wait swallowed cancellation"

  , testCase "state wait rejects references from another adoption before attaching" $
      withServer $ \fixture server session _ -> do
        (slot, pane) <- stateTarget server session
        let config = (Tmux.serverConfig (Os.fromBytestring (Ascii.pack fixture.socket)))
              {Tmux.executable = Os.fromBytestring (Ascii.pack fixture.executable)}
        void (native fixture ["set-hook", "client-attached", "set-option -g @state-wait-attached yes"])
        Tmux.withServer config $ \other -> do
          graph <- Tmux.capture other
          case (Tmux.sessions graph, Tmux.panes graph) of
            ([foreignSession], [foreignPane]) -> do
              idx <- either (fail . show) pure (Tmux.mkWindowIndex 0)
              let foreignSlot = Tmux.WindowSlot foreignSession.ref idx
              forM_ [(slot, foreignPane.ref), (foreignSlot, pane)] $ \(target, ref) ->
                Tmux.tryTmux (Tmux.waitForPaneState server target ref Tmux.PaneActive Tmux.defaultPaneStateWait) >>= \case
                  Left (ExceptionWithContext _ Tmux.InvalidTarget) -> pure ()
                  _ -> assertFailure "foreign generation reached the observer"
            _ -> assertFailure "expected one session and one pane"
        native fixture ["show-options", "-gqv", "@state-wait-attached"] >>= (@?= "")

  , testCase "retains the owner when cancellation cannot join a held launch" $
      Fixture.withFixture $ \fixture -> withWitness $ \remember -> do
        runtime <- Runtime.newRuntime Process.normalFork
        Scope.runScope runtime $ do
          serverHandle <- Runtime.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack (takeDirectory fixture.socket))
          let pool = Runtime.serverPool serverHandle
              executable = Ascii.pack fixture.executable
              arguments = [executable, "-u", "-N", "-S", Pin.pinPath (Runtime.serverPin serverHandle),
                "-C", "attach-session", "-E", "-f", "ignore-size,no-output", "-t", "$0"]
              spec = N.spec executable arguments
          launch <- newIORef Nothing
          ready <- newEmptyTMVarIO
          release <- newEmptyTMVarIO
          let hooks = Process.defaultHooks
                { Process.launchNative = \request -> do
                    started <- N.launch request
                    writeIORef launch (Just started)
                    pure started
                , Process.afterStart = do
                    started <- readIORef launch
                    independent <- case started of
                      Just (N.Owned child) -> remember $ do
                        Fd fd <- dup (Fd child.pidfd)
                        pure fd
                      _ -> fail "native control launch failed"
                    atomically (putTMVar ready independent)
                    atomically (takeTMVar release)
                }
              open = Control.withControlClientUsing hooks 50000 pool spec 2000000 "$0"
                Control.defaultControlOptions (const (assertFailure "callback entered before attachment"))
          flip finally (atomically (void (tryPutTMVar release ()))) $
            withAsync (tryWithContext @SomeException open) $ \worker -> do
              independent <- bounded (atomically (takeTMVar ready))
              bracket (threadWaitReadSTM (Fd independent)) snd $ \(awaitExit, _) -> do
                throwTo (asyncThreadId worker) ThreadKilled
                owner <- bounded (wait worker) >>= \case
                  Left (ExceptionWithContext context problem) -> do
                    fromException problem @?= Just ThreadKilled
                    case Control.controlRecoveries context of
                      [recovery] -> pure recovery
                      _ -> fail "cancellation lost the held control owner"
                  Right _ -> fail "scope swallowed cancellation"
                atomically (Control.controlRetired owner) >>= (@?= False)
                atomically ((awaitExit >> pure True) `orElse` pure False) >>= (@?= False)
                atomically (putTMVar release ())
                Control.resumeControlCleanup owner >>= (@?= True)
                bounded (atomically awaitExit)
  ]

withServer :: (Fixture.Fixture -> Tmux.Server -> Tmux.SessionRef -> Tmux.WindowRef -> Assertion)
  -> Assertion
withServer action = Fixture.withFixture $ \fixture -> do
  let config = (Tmux.serverConfig (Os.fromBytestring (Ascii.pack fixture.socket)))
        {Tmux.executable = Os.fromBytestring (Ascii.pack fixture.executable)}
  Tmux.withServer config $ \server -> do
    snapshot <- Tmux.capture server
    case (Tmux.sessions snapshot, Tmux.windows snapshot) of
      ([session], [window]) -> action fixture server session.ref window.ref
      _ -> assertFailure "expected one fixture session and window"

paneTarget :: Tmux.PaneRef -> String
paneTarget = Ascii.unpack . Utf8.encodeUtf8 . Tmux.renderPaneId . Tmux.paneId

stateSession :: Tmux.Server -> IO Tmux.CreatedSession
stateSession server = Tmux.createSession server
  Creation.defaultSessionOptions {Creation.name = Just "state-bystander",
    Creation.process = Creation.ShellCommand "exec /bin/cat -"}

signalAttachment :: Fixture.Fixture -> Tmux.SessionRef -> IO ()
signalAttachment fixture session =
  void (native fixture ["set-hook", "-t", sessionTarget session, "client-attached", "wait-for -S pane-state-attached"])

sessionTarget :: Tmux.SessionRef -> String
sessionTarget = Ascii.unpack . Utf8.encodeUtf8 . Tmux.renderSessionId . Tmux.sessionId

awaitAttachment :: Fixture.Fixture -> IO ()
awaitAttachment fixture = void (bounded (native fixture ["wait-for", "pane-state-attached"]))

stateTarget :: Tmux.Server -> Tmux.SessionRef -> IO (Tmux.WindowSlot, Tmux.PaneRef)
stateTarget server session = do
  graph <- Tmux.capture server
  case (Tmux.panes graph, Tmux.linksForSession graph session) of
    ([pane], Right [link]) -> pure (Tmux.WindowSlot session link.index, pane.ref)
    _ -> fail "expected one fixture pane and link"

settleRead :: Tmux.Server -> Maybe Recovery.CaptureRecovery -> IO ()
settleRead server = mapM_ $ \owner -> do
  Recovery.recoveryGeneration owner @?= Tmux.serverGeneration server
  bounded (Recovery.resumeCaptureRecovery owner)
  void (Recovery.detachCaptureRecovery owner)

matchedState :: Tmux.PaneStateWaitResult -> IO Tmux.Snapshot
matchedState = \case
  Tmux.PaneStateMatched snapshot -> pure snapshot
  _ -> fail "state wait did not confirm the requested state"

withWitness :: ((IO CInt -> IO CInt) -> Assertion) -> Assertion
withWitness action = do
  remembered <- newIORef Nothing
  let acquire open = mask_ $ do
        fd <- open
        writeIORef remembered (Just fd)
        pure fd
  flip finally (readIORef remembered >>= mapM_ N.close) $ do
    action acquire
    readIORef remembered >>= mapM_ (\fd -> bounded (threadWaitRead (Fd fd)))

clientWitness :: Fixture.Fixture -> IO CInt
clientWitness fixture = do
  output <- native fixture ["list-clients", "-F", "#{client_pid}"]
  pid <- maybe (fail "expected one control client PID") pure (readMaybe (Ascii.unpack output))
  N.openPid pid

native :: Fixture.Fixture -> [String] -> IO Bytes.ByteString
native fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, errors) @?= (ExitSuccess, "")
  pure (Lazy.toStrict output)

awaitRename :: Tmux.Control -> IO (Tmux.WindowId, Bytes.ByteString)
awaitRename stream = atomically (Tmux.readControlEvent stream) >>= \case
  Right (Tmux.WindowRenamed window label) -> pure (window, label)
  Right _ -> awaitRename stream
  Left reason -> fail ("stream ended before the rename: " <> show reason)

awaitEnd :: Tmux.Control -> IO Tmux.ControlEnd
awaitEnd stream = atomically (Tmux.readControlEvent stream) >>= \case
  Right _ -> awaitEnd stream
  Left reason -> pure reason

awaitPaneOutput :: Tmux.Control -> Tmux.PaneId -> IO ()
awaitPaneOutput stream pane = loop ""
  where
    prefix = "%output " <> Utf8.encodeUtf8 (Tmux.renderPaneId pane) <> " "
    needle = "pane-stream"
    loop carried = atomically (Tmux.readControlEvent stream) >>= \case
      Right (Tmux.ControlNotification line) | Just fragment <- Bytes.stripPrefix prefix line -> do
        let combined = carried <> fragment
        if needle `Bytes.isInfixOf` combined then pure ()
        else loop (Bytes.drop (max 0 (Bytes.length combined + 1 - Bytes.length needle)) combined)
      Right _ -> loop carried
      Left reason -> fail ("stream ended before pane output: " <> show reason)

awaitBlocked :: ThreadId -> IO ()
awaitBlocked thread = threadStatus thread >>= \case
  ThreadBlocked BlockedOnSTM -> pure ()
  ThreadFinished -> fail "control consumer exited before blocking"
  ThreadDied -> fail "control consumer failed before blocking"
  _ -> yield >> awaitBlocked thread

bounded :: IO value -> IO value
bounded action = timeout 1000000 action >>= maybe (fail "control event deadline") pure
