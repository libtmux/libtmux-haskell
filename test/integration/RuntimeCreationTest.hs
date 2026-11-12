module RuntimeCreationTest (tests) where

import Control.Concurrent.STM
import Control.Exception
import Control.Exception.Context qualified as Context
import Data.List.NonEmpty (NonEmpty (..))
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Snapshot qualified as Snapshot
import LibTmux.Value qualified as Value
import System.Directory (createDirectory)
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "owned Runtime creation"
  [ testCase "literal options return native identities and survive Runtime closure" $ do
      (journal, expected) <- withRuntime P.normalFork $ \runtime server fixture -> do
        let cwd = Ascii.pack fixture.directory <> "/#{pid};"
        createDirectory (Ascii.unpack cwd)
        width <- require (Value.mkDimension 120)
        height <- require (Value.mkDimension 40)
        configured fixture server ["set-option", "-g", "status", "off"]
        configured fixture server ["set-option", "-g", "update-environment", "LIBTMUX_CLIENT_CONTEXT"]
        let options = (optionsFor "literal-#{pid}")
              { C.windowName = Just (Snapshot.labelFromBytes "#[#{pid}];")
              , C.workingDirectory = Just (Os.fromBytestring cwd)
              , C.environment = [(Os.fromBytestring "KEY", Os.fromBytestring "#{pid};")]
              , C.width = Just width, C.height = Just height }
            context = (launchContext fixture)
              {N.env = ["LANG=C.UTF-8", "LIBTMUX_CLIENT_CONTEXT=from-launch"]}
        created <- R.createSessionWith P.defaultHooks 1000000 runtime server context options
        withCreated fixture server created $ \receipt -> do
          reply created >>= (@?= C.SessionCreated receipt)
          let sid = sessionTarget receipt
          readOutput fixture server ["display-message", "-p", "-t", sid <> ":", "-F",
            "#{session_name}|#{window_name}|#{pane_start_path}|#{pane_start_command}|#{pane_width}|#{pane_height}"] >>=
              (@?= "literal-#{pid}|#[#{pid}];|" <> cwd <> "|/bin/cat -|120|40\n")
          readOutput fixture server ["show-environment", "-t", sid, "KEY"] >>= (@?= "KEY=#{pid};\n")
          readOutput fixture server ["show-environment", "-t", sid, "LIBTMUX_CLIENT_CONTEXT"] >>=
            (@?= "LIBTMUX_CLIENT_CONTEXT=from-launch\n")
          R.receiptGeneration (R.readReceipt (R.creationRequest created)) @?= Pin.pinGeneration (R.serverPin server)
          atomically (R.readStatus (R.creationRequest created)) >>=
            (@?= S.Status S.OperationComplete (Just S.Succeeded) False)
          pure (R.creationJournal created, receipt)
      atomically (R.journalReceipt journal) >>= (@?= Just expected)

  , testCase "unspecified cwd uses the supplied native client context" $
      withRuntime P.normalFork $ \runtime server fixture -> do
        created <- start 1000000 runtime server fixture (optionsFor "context-cwd")
        withCreated fixture server created $ \receipt -> do
          reply created >>= (@?= C.SessionCreated receipt)
          readOutput fixture server ["display-message", "-p", "-t", paneTarget receipt, "-F", "#{pane_start_path}"] >>=
            (@?= Ascii.pack fixture.directory <> "\n")

  , testCase "duplicate rejection has no creation evidence and releases admission" $
      withRuntime P.normalFork $ \runtime server fixture -> do
        created <- start 1000000 runtime server fixture (optionsFor "duplicate")
        withCreated fixture server created $ \_ -> do
          _ <- reply created
          duplicate <- start 1000000 runtime server fixture (optionsFor "duplicate")
          reply duplicate >>= \case
            C.SessionCreationRejected diagnostic -> assertBool "empty duplicate diagnostic" (not (Bytes.null diagnostic))
            other -> assertFailure (show other)
          bounded (atomically (evidenceOrTerminal duplicate)) >>= (@?= Nothing)
          atomically (R.readStatus (R.creationRequest duplicate)) >>=
            (@?= S.Status S.OperationComplete (Just S.Failed) False)

  , testCase "following hook errors retain the primary creation identity" $
      withRuntime P.normalFork $ \runtime server fixture ->
        withHook fixture server "has-session -t =libtmux-missing-created" $ do
          created <- start 1000000 runtime server fixture (optionsFor "hook-error")
          withCreated fixture server created $ \receipt ->
            reply created >>= \case
              C.SessionCreatedWithErrors observed diagnostic -> do
                observed @?= receipt
                assertBool "empty hook diagnostic" (not (Bytes.null diagnostic))
              other -> assertFailure (show other)

  , testCase "a destructive hook does not erase a historical receipt" $
      withRuntime P.normalFork $ \runtime server fixture ->
        withHook fixture server "wait-for release-created ; kill-session -t =destroyed-created" $
          flip finally (configured fixture server ["wait-for", "-S", "release-created"]) $ do
            created <- start 1000000 runtime server fixture (optionsFor "destroyed-created")
            withCreated fixture server created $ \receipt -> do
              configured fixture server ["wait-for", "-S", "release-created"]
              reply created >>= (@?= C.SessionCreated receipt)
              missing <- invoke fixture server ["has-session", "-t", sessionTarget receipt]
              missing.exit @?= Just (N.Exited 1)
              atomically (R.journalReceipt (R.creationJournal created)) >>= (@?= Just receipt)

  , testCase "cancellation retains correlated IDs and leaves inspection available" $
      withRuntime P.normalFork $ \runtime server fixture ->
        withHook fixture server "wait-for release-created" $
          flip finally (configured fixture server ["wait-for", "-S", "release-created"]) $ do
            created <- start 1000000 runtime server fixture (optionsFor "cancel-created")
            withCreated fixture server created $ \receipt -> do
              inspectPid runtime server fixture
              R.cancelRead runtime (R.creationRequest created)
              unavailable created
              let correlation = R.readReceipt (R.creationRequest created)
              recovery <- settled runtime server correlation
              recovery.logical.outcome @?= Just S.OutcomeUnknown
              recovery.logical.retained @?= True
              atomically (R.journalReceipt (R.creationJournal created)) >>= (@?= Just receipt)
              R.resumeReceipt runtime server correlation
              atomically (R.detachReceipt runtime server correlation) >>= (@?= True)
              configured fixture server ["wait-for", "-S", "release-created"]
              inspectPid runtime server fixture
              configured fixture server ["set-hook", "-gu", "after-new-session"]
              next <- start 1000000 runtime server fixture (optionsFor "after-recovery")
              withCreated fixture server next $ \nextReceipt -> reply next >>= (@?= C.SessionCreated nextReceipt)

  , testCase "deadline after a receipt preserves uncertainty without replay" $
      withRuntime P.normalFork $ \runtime server fixture ->
        withHook fixture server "wait-for release-created" $
          flip finally (configured fixture server ["wait-for", "-S", "release-created"]) $ do
            created <- start 250000 runtime server fixture (optionsFor "expired-created")
            withCreated fixture server created $ \receipt -> do
              unavailable created
              atomically (R.journalReceipt (R.creationJournal created)) >>= (@?= Just receipt)
              let correlation = R.readReceipt (R.creationRequest created)
              recovery <- settled runtime server correlation
              recovery.logical.retained @?= True
              atomically (R.detachReceipt runtime server correlation) >>= (@?= True)

  , testCase "queued creation cancellation cannot fabricate a receipt" $
      withRuntime P.normalFork $ \runtime server fixture ->
        withHook fixture server "wait-for release-created" $
          flip finally (configured fixture server ["wait-for", "-S", "release-created"]) $ do
            first <- start 1000000 runtime server fixture (optionsFor "first-created")
            withCreated fixture server first $ \receipt -> do
              queued <- start 1000000 runtime server fixture (optionsFor "queued-created")
              atomically (R.readStatus (R.creationRequest queued)) >>= \state -> state.stage @?= S.Queued
              R.cancelRead runtime (R.creationRequest queued)
              bounded (R.awaitRead (R.creationRequest queued)) >>= \case
                R.ReadUnavailable S.NotDispatched _ -> pure ()
                _ -> assertFailure "queued creation acquired an uncertain outcome"
              atomically (R.journalReceipt (R.creationJournal queued)) >>= (@?= Nothing)
              configured fixture server ["wait-for", "-S", "release-created"]
              reply first >>= (@?= C.SessionCreated receipt)

  , testCase "allocation failure keeps the async class, journal and operation correlation" $ do
      first <- newIORef True
      let fork :: P.Fork
          fork action = atomicModifyIORef' first (\old -> (False, old)) >>= \case
            True -> throwIO ThreadKilled
            False -> P.normalFork action
      withRuntime fork $ \runtime server fixture -> do
        tryWithContext @SomeException (start 1000000 runtime server fixture (optionsFor "unallocated")) >>= \case
          Left (ExceptionWithContext context problem) -> do
            fromException @AsyncException problem @?= Just ThreadKilled
            case (Context.getExceptionAnnotations @R.CreationJournal context,
                  Context.getExceptionAnnotations @R.ReadReceipt context) of
              ([journal], [correlation]) -> do
                atomically (R.journalReceipt journal) >>= (@?= Nothing)
                recovery <- settled runtime server correlation
                recovery.logical.outcome @?= Just S.NotDispatched
                recovery.logical.retained @?= False
              _ -> assertFailure "creation allocation failure lost its correlation"
          Right _ -> assertFailure "worker-allocation failure returned success"

  , testCase "synchronous creation retains journals before Request handoff fails" $
      forM_ [False, True] $ \expires -> do
        first <- newIORef True
        gate <- newEmptyTMVarIO
        let fork :: P.Fork
            fork action = atomicModifyIORef' first (\old -> (False, old)) >>= \case
              True | expires -> atomically (readTMVar gate) >> fail "unexpected allocation"
                   | otherwise -> throwIO ThreadKilled
              False -> P.normalFork action
            duration = if expires then 20000 else 1000000
        withRuntime fork $ \runtime server fixture -> do
          let options = (optionsFor "before-handoff") {C.process = C.ShellCommand "exec /bin/cat -"}
          bounded (tryWithContext @SomeException (Create.performCreation P.defaultHooks duration
            runtime server (Ascii.pack fixture.executable) options)) >>= \case
              Left (ExceptionWithContext context problem) -> do
                if expires then case fromException @Scope.TmuxException problem of
                  Just Scope.MutationTimedOut -> pure ()
                  _ -> assertFailure "allocation timeout changed exception"
                else fromException @AsyncException problem @?= Just ThreadKilled
                recovery <- case Context.getExceptionAnnotations @Create.CreationRecovery context of
                  [value] -> pure value
                  _ -> fail "pre-Request failure lost creation recovery"
                atomically (Create.observedReceipt recovery) >>= (@?= Nothing)
                observed <- bounded (Create.awaitRecovery recovery)
                observed.logical.outcome @?= Just S.NotDispatched
                observed.logical.retained @?= False
              Right _ -> assertFailure "failed allocation returned a creation"

  , testCase "invalid options and launch contexts create no operation" $
      withRuntime P.normalFork $ \runtime server fixture -> do
        forM_ [(launchContext fixture, (optionsFor "bad") {C.name = Just "bad\NULname"}),
               ((launchContext fixture) {N.env = ["invalid"]}, optionsFor "bad-env"),
               ((launchContext fixture) {N.cwd = "relative"}, optionsFor "bad-cwd")] $ \(context, options) -> do
          try @SomeException (R.createSessionWith P.defaultHooks 1000000 runtime server context options) >>= \case
            Left _ -> pure ()
            Right _ -> assertFailure "invalid creation input was admitted"
        atomically (R.inspect runtime) >>= \report -> do
          length report.readWorkers @?= 0
          length report.unresolved @?= 0

  , testCase "a foreign Runtime cannot admit creation through another owner" $
      withRuntime P.normalFork $ \runtime server fixture ->
        bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \other -> do
          try @R.ReadError (start 1000000 other server fixture (optionsFor "foreign")) >>= \case
            Left R.ForeignServer -> pure ()
            _ -> assertFailure "foreign Runtime admitted creation"
          forM_ [runtime, other] $ \selected -> atomically (R.inspect selected) >>= \report -> do
            length report.readWorkers @?= 0
            length report.unresolved @?= 0

  , testCase "malformed completion retains IDs and uncertainty after native cleanup" $
      withRuntime P.normalFork $ \runtime server fixture -> do
        let hooks = P.defaultHooks {P.launchNative = \spec -> N.launch spec
              {N.file = "/bin/sh", N.args = ["/bin/sh", "-c",
                "\"$@\" || exit; printf 'after-exit\\n'", "corrupt-footer"] <> spec.args}}
        created <- R.createSessionWith hooks 1000000 runtime server (launchContext fixture) (optionsFor "malformed-created")
        withCreated fixture server created $ \receipt -> do
          unavailable created
          let correlation = R.readReceipt (R.creationRequest created)
          recovery <- settled runtime server correlation
          recovery.logical.outcome @?= Just S.OutcomeUnknown
          recovery.logical.retained @?= True
          atomically (R.journalReceipt (R.creationJournal created)) >>= (@?= Just receipt)
          atomically (R.detachReceipt runtime server correlation) >>= (@?= True)

  , testCase "overflow after receipt retains IDs while releasing physical ownership" $
      withRuntime P.normalFork $ \runtime server fixture ->
        -- tmux caps each padding modifier at 10000 cells.
        withHook fixture server ("display-message -p '" <> Bytes.concat (replicate 110 "#{p10000:x}") <> "'") $ do
          created <- start 1000000 runtime server fixture (optionsFor "overflow-created")
          withCreated fixture server created $ \receipt -> do
            unavailable created
            let correlation = R.readReceipt (R.creationRequest created)
            recovery <- settled runtime server correlation
            recovery.logical.retained @?= True
            atomically (R.journalReceipt (R.creationJournal created)) >>= (@?= Just receipt)
            atomically (R.detachReceipt runtime server correlation) >>= (@?= True)
  ]

optionsFor :: ByteString -> C.SessionOptions
optionsFor name = C.defaultSessionOptions
  {C.name = Just (Utf8.decodeUtf8 name)
  ,C.process = C.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])}

launchContext :: Fixture.Fixture -> N.Spec
launchContext fixture = (N.spec (Ascii.pack fixture.executable) []) {N.cwd = Ascii.pack fixture.directory}

start :: Int -> R.Runtime -> R.ServerHandle -> Fixture.Fixture -> C.SessionOptions -> IO R.SessionCreation
start duration runtime server fixture = R.createSessionWith P.defaultHooks duration runtime server (launchContext fixture)

reply :: R.SessionCreation -> IO C.SessionCreationReply
reply created = bounded (R.awaitRead (R.creationRequest created)) >>= \case
  R.ReadValue value -> pure value
  R.ReadUnavailable outcome problem -> assertFailure (show (outcome, problem)) >> fail "unavailable creation"

unavailable :: R.SessionCreation -> Assertion
unavailable created = bounded (R.awaitRead (R.creationRequest created)) >>= \case
  R.ReadUnavailable S.OutcomeUnknown _ -> pure ()
  _ -> assertFailure "uncertain creation returned success"

evidenceOrTerminal :: R.SessionCreation -> STM (Maybe C.SessionReceipt)
evidenceOrTerminal created = do
  found <- R.journalReceipt (R.creationJournal created)
  case found of
    Just receipt -> pure (Just receipt)
    Nothing -> do
      state <- R.readStatus (R.creationRequest created)
      case state.outcome of
        Nothing -> retry
        Just _ -> pure Nothing

withCreated :: Fixture.Fixture -> R.ServerHandle -> R.SessionCreation -> (C.SessionReceipt -> IO a) -> IO a
withCreated fixture server created action = do
  receipt <- bounded (atomically (evidenceOrTerminal created)) >>= maybe (fail "creation ended without a receipt") pure
  pid <- readOutput fixture server ["display-message", "-p", "-t", paneTarget receipt, "-F", "#{pane_pid}"]
  Fixture.withTrackedPane (Lazy.fromStrict pid)
    (void (invoke fixture server ["kill-session", "-t", sessionTarget receipt])) (action receipt)

sessionTarget, paneTarget :: C.SessionReceipt -> ByteString
sessionTarget = Utf8.encodeUtf8 . Id.renderSessionId . (.sessionId)
paneTarget = Utf8.encodeUtf8 . Id.renderPaneId . (.paneId)

settled :: R.Runtime -> R.ServerHandle -> R.ReadReceipt -> IO R.ReadRecovery
settled runtime server correlation = bounded $ atomically $ do
  recovery <- R.inspectReceipt runtime server correlation
  check (not recovery.workerOwned && not recovery.nativeOwned)
  pure recovery

inspectPid :: R.Runtime -> R.ServerHandle -> Fixture.Fixture -> Assertion
inspectPid runtime server fixture = do
  request <- R.readServerPid runtime server (Ascii.pack fixture.executable) R.InspectionRead
  bounded (R.awaitRead request) >>= \case
    R.ReadValue pid -> assertBool "nonpositive daemon PID" (pid > 0)
    other -> assertFailure (show other)

withRuntime :: P.Fork -> (R.Runtime -> R.ServerHandle -> Fixture.Fixture -> IO a) -> IO a
withRuntime fork action = Fixture.withFixture $ \fixture -> bracket (R.newRuntime fork) R.awaitCleanup $ \runtime -> do
  server <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
  action runtime server fixture

withHook :: Fixture.Fixture -> R.ServerHandle -> ByteString -> IO a -> IO a
withHook fixture server hook = bracket_
  (configured fixture server ["set-hook", "-g", "after-new-session", hook])
  (configured fixture server ["set-hook", "-gu", "after-new-session"])

invoke :: Fixture.Fixture -> R.ServerHandle -> [ByteString] -> IO P.Completion
invoke fixture server arguments = do
  let executable = Ascii.pack fixture.executable
      spec = N.spec executable ([executable, "-u", "-N", "-S", Pin.pinPath (R.serverPin server)] <> arguments)
  P.submit B.Inspection P.defaultHooks (R.serverPool server) spec "" >>= bounded . P.await

configured :: Fixture.Fixture -> R.ServerHandle -> [ByteString] -> Assertion
configured fixture server arguments = do
  completed <- invoke fixture server arguments
  (completed.exit, completed.output, completed.errors) @?= (Just (N.Exited 0), "", "")

readOutput :: Fixture.Fixture -> R.ServerHandle -> [ByteString] -> IO ByteString
readOutput fixture server arguments = do
  completed <- invoke fixture server arguments
  (completed.exit, completed.errors) @?= (Just (N.Exited 0), "")
  pure completed.output

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "creation event did not arrive") pure

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
