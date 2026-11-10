module RuntimeMutationTest (tests) where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM, forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.IORef
import Fixture qualified
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Internal.TmuxText qualified as Label
import ProcessGate qualified as G
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "owned Runtime mutations"
  [ testCase "completed mutation values survive closure and release admission" $ do
      detached <- withRuntime P.normalFork $ \runtime client fixture -> do
        session <- require (Id.parseSessionId "$0")
        window <- require (Id.parseWindowId "@0")
        pane <- require (Id.parsePaneId "%0")
        missing <- require (Id.parseWindowId "@999999")
        values <- forM [C.RenameSession session "session", C.RenameWindow window "#[#{pid}];",
                       C.SetPaneTitle pane "title", C.RenameWindow missing "absent"] $ \mutation -> do
          request <- start P.defaultHooks runtime client fixture mutation
          value <- reply request
          case mutation of
            C.RenameWindow ident _ | ident == missing -> case value of
              C.Rejected diagnostic -> Bytes.null diagnostic @?= False
              other -> assertFailure (show other)
            _ -> value @?= C.Applied
          let outcome = if value == C.Applied then S.Succeeded else S.Failed
          atomically (R.readStatus request) >>= (@?= S.Status S.OperationComplete (Just outcome) False)
          pure (request, value)
        atomically (R.inspect runtime) >>= \report -> do
          length report.readWorkers @?= 0
          length report.unresolved @?= 0
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        pure values
      forM_ detached $ \(request, expected) -> reply request >>= (@?= expected)

  , testCase "an after-hook error preserves its applied result and releases the lane" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        window <- require (Id.parseWindowId "@0")
        configured fixture client ["set-hook", "-g", "after-rename-window", "has-session -t =libtmux-missing"]
        flip finally (configured fixture client ["set-hook", "-gu", "after-rename-window"]) $ do
          request <- start P.defaultHooks runtime client fixture (C.RenameWindow window "effect-before-error")
          reply request >>= \case
            C.AppliedWithErrors diagnostic -> Bytes.null diagnostic @?= False
            other -> assertFailure (show other)
          atomically (R.readStatus request) >>= (@?= S.Status S.OperationComplete (Just S.Failed) False)
          field fixture client "window_name" >>= (@?= "effect-before-error\n")
        start P.defaultHooks runtime client fixture (C.RenameWindow window "later") >>= reply >>= (@?= C.Applied)

  , testCase "queued mutation cancellation preserves serialization and inspection progress" $
      withRuntime P.normalFork $ \runtime client fixture -> G.withGate $ \gate -> do
        window <- require (Id.parseWindowId "@0")
        let hooks = P.defaultHooks {P.launchNative = G.launch G.BeforeLaunch gate}
        first <- start hooks runtime client fixture (C.RenameWindow window "first")
        bounded (G.awaitGate gate)
        flip finally (G.releaseGate gate) $ do
          second <- start P.defaultHooks runtime client fixture (C.RenameWindow window "undispatched")
          atomically (R.readStatus second) >>= \status -> status.stage @?= S.Queued
          inspectPid runtime client fixture
          R.cancelRead runtime second
          unavailable S.NotDispatched second
          atomically (R.readStatus first) >>= \status -> status.retained @?= True
        reply first >>= (@?= C.Applied)
        field fixture client "window_name" >>= (@?= "first\n")

  , testCase "cancellation during an accepted waiting hook retains correlated uncertainty" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        window <- require (Id.parseWindowId "@0")
        configured fixture client ["set-hook", "-g", "after-rename-window",
          "wait-for -S libtmux-mutation-entered ; wait-for libtmux-mutation-release"]
        entered <- submit fixture client ["wait-for", "libtmux-mutation-entered"]
        let release = do
              configured fixture client ["wait-for", "-S", "libtmux-mutation-entered"]
              configured fixture client ["wait-for", "-S", "libtmux-mutation-release"]
              configured fixture client ["set-hook", "-gu", "after-rename-window"]
        flip finally release $ do
          request <- start P.defaultHooks runtime client fixture (C.RenameWindow window "accepted-before-cancel")
          completed <- bounded (P.await entered)
          (completed.exit, completed.errors) @?= (Just (N.Exited 0), "")
          field fixture client "window_name" >>= (@?= "accepted-before-cancel\n")
          inspectPid runtime client fixture
          R.cancelRead runtime request
          unavailable S.OutcomeUnknown request
          let receipt = R.readReceipt request
          observed <- bounded $ atomically $ do
            current <- R.inspectReceipt runtime client receipt
            check (not current.workerOwned && not current.nativeOwned)
            pure current
          observed.logical.retained @?= True
          observed.logical.outcome @?= Just S.OutcomeUnknown
          queued <- start P.defaultHooks runtime client fixture (C.RenameWindow window "after-detach")
          atomically (R.readStatus queued) >>= \status -> status.stage @?= S.Queued
          release
          atomically (R.detachReceipt runtime client receipt) >>= (@?= True)
          reply queued >>= (@?= C.Applied)
          atomically (R.readStatus request) >>= \status -> status.outcome @?= Just S.OutcomeUnknown

  , testCase "detaching uncertainty leaves native cleanup owned until its gate returns" $
      withRuntime P.normalFork $ \runtime client fixture -> G.withGate $ \gate -> do
        window <- require (Id.parseWindowId "@0")
        let hooks = P.defaultHooks {P.launchNative = G.launch G.AfterLaunch gate}
        request <- start hooks runtime client fixture (C.RenameWindow window "accepted")
        bounded (G.awaitGate gate)
        flip finally (G.releaseGate gate) $ do
          R.cancelRead runtime request
          unavailable S.OutcomeUnknown request
          let receipt = R.readReceipt request
          atomically (R.detachReceipt runtime client receipt) >>= (@?= True)
          atomically (R.inspectReceipt runtime client receipt) >>= \observed -> do
            observed.logical.retained @?= False
            observed.nativeOwned @?= True
        bounded $ atomically $ do
          observed <- R.inspectReceipt runtime client (R.readReceipt request)
          check (not observed.workerOwned && not observed.nativeOwned)
        unavailable S.OutcomeUnknown request

  , testCase "hook data cannot become a control response" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        window <- require (Id.parseWindowId "@0")
        configured fixture client ["set-option", "-g", "@libtmux-hook-data", "%error 0 0 1\n%exit"]
        configured fixture client ["set-hook", "-g", "after-rename-window", "display-message -p '#{@libtmux-hook-data}'"]
        flip finally (configured fixture client ["set-hook", "-gu", "after-rename-window"]) $ do
          request <- start P.defaultHooks runtime client fixture (C.RenameWindow window "effect-with-noise")
          reply request >>= (@?= C.Applied)
          atomically (R.inspectReceipt runtime client (R.readReceipt request)) >>= \observed ->
            observed.logical.retained @?= False
          field fixture client "window_name" >>= (@?= "effect-with-noise\n")

  , testCase "mutations do not invoke unrelated display hooks" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        window <- require (Id.parseWindowId "@0")
        configured fixture client ["set-option", "-g", "@libtmux-display-calls", ""]
        configured fixture client ["set-hook", "-g", "after-display-message",
          "set-option -ga @libtmux-display-calls x"]
        flip finally (configured fixture client ["set-hook", "-gu", "after-display-message"]) $ do
          start P.defaultHooks runtime client fixture (C.RenameWindow window "literal") >>= reply >>= (@?= C.Applied)
          completed <- submit fixture client ["show-options", "-g", "-v", "@libtmux-display-calls"] >>= bounded . P.await
          (completed.exit, completed.errors, completed.output) @?= (Just (N.Exited 0), "", "\n")

  , testCase "invalid operands, deadlines and foreign handles refuse before worker allocation" $ do
      forks <- newIORef (0 :: Int)
      let tracked :: P.Fork
          tracked action = modifyIORef' forks (+ 1) >> P.normalFork action
      withRuntime tracked $ \runtime client fixture -> do
        window <- require (Id.parseWindowId "@0")
        try @R.ReadError (start P.defaultHooks runtime client fixture (C.RenameWindow window (Label.fromBytes "x\NULy"))) >>= \case
          Left (R.InvalidCommandOperands (C.NulOperand "window.name")) -> pure ()
          other -> assertFailure (either show (const "NUL admitted") other)
        forM_ [0, -1, 10000001] $ \duration ->
          try @R.ReadError (R.mutateWith P.defaultHooks duration runtime client (Ascii.pack fixture.executable)
            (C.RenameWindow window "invalid-deadline")) >>= \case
              Left (R.InvalidReadDeadline actual) -> actual @?= duration
              _ -> assertFailure "invalid deadline admitted"
        bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \other ->
          try @R.ReadError (start P.defaultHooks other client fixture (C.RenameWindow window "foreign")) >>= \case
            Left R.ForeignServer -> pure ()
            _ -> assertFailure "foreign handle admitted"
        readIORef forks >>= (@?= 0)
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
  ]

withRuntime :: P.Fork -> (R.Runtime -> R.ServerHandle -> Fixture.Fixture -> IO a) -> IO a
withRuntime fork action = Fixture.withFixture $ \fixture ->
  bracket (R.newRuntime fork) R.awaitCleanup $ \runtime -> do
    client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
    action runtime client fixture

start :: P.Hooks -> R.Runtime -> R.ServerHandle -> Fixture.Fixture -> C.Mutation -> IO (R.Request C.MutationReply)
start hooks runtime client fixture = R.mutateWith hooks 1000000 runtime client (Ascii.pack fixture.executable)

reply :: R.Request C.MutationReply -> IO C.MutationReply
reply request = bounded (R.awaitRead request) >>= \case
  R.ReadValue value -> pure value
  other -> assertFailure (show other) >> fail "unavailable reply"

unavailable :: S.Outcome -> R.Request value -> Assertion
unavailable expected request = bounded (R.awaitRead request) >>= \case
  R.ReadUnavailable actual _ -> actual @?= expected
  _ -> assertFailure "uncertain request returned a successful value"

inspectPid :: R.Runtime -> R.ServerHandle -> Fixture.Fixture -> Assertion
inspectPid runtime client fixture = do
  request <- R.readServerPid runtime client (Ascii.pack fixture.executable) R.InspectionRead
  bounded (R.awaitRead request) >>= \case
    R.ReadValue pid -> assertBool "nonpositive PID" (pid > 0)
    other -> assertFailure (show other)

submit :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> IO P.Ticket
submit fixture client arguments = do
  let executable = Ascii.pack fixture.executable
      spec = N.spec executable ([executable, "-u", "-N", "-S", Pin.pinPath (R.serverPin client)] <> arguments)
  P.submit B.Inspection P.defaultHooks (R.serverPool client) spec ""

configured :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> Assertion
configured fixture client arguments = do
  completed <- submit fixture client arguments >>= bounded . P.await
  (completed.exit, completed.output, completed.errors) @?= (Just (N.Exited 0), "", "")

field :: Fixture.Fixture -> R.ServerHandle -> Bytes.ByteString -> IO Bytes.ByteString
field fixture client name = do
  completed <- submit fixture client ["display-message", "-p", "-t", "%0", "-F", "#{" <> name <> "}"]
    >>= bounded . P.await
  (completed.exit, completed.errors) @?= (Just (N.Exited 0), "")
  pure completed.output

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "mutation test did not receive its event") pure

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
