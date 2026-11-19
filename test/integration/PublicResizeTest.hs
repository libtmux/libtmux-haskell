module PublicResizeTest (tests) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Exception
import Control.Monad (forM_, void)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Fixture qualified
import LibTmux qualified as Tmux
import LibTmux.Recovery qualified as Recovery
import LibTmux.Creation qualified as Creation
import LibTmux.Snapshot.Fixture qualified as F
import System.Exit (ExitCode (..))
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public absolute resizing"
  [ testCase "pane axes target an inactive pane and retain native clamping" $
      withLayout $ \_ server base -> do
        before <- Tmux.capture server
        target <- require (Tmux.lookupPane before base.pane)
        target.active @?= False
        width <- dimension 50
        height <- dimension 10
        columns <- dimension 70
        rows <- dimension 15
        largest <- dimension 10000
        forM_ [(Tmux.ResizeWidth width, (50, 39)), (Tmux.ResizeHeight height, (50, 10)),
               (Tmux.ResizeBoth columns rows, (70, 15)), (Tmux.ResizeWidth largest, (118, 15))] $ \(size, expected) -> do
          Tmux.resizePane server base.pane size
          after <- Tmux.capture server
          assertPaneGeometry after base.pane expected
          assertWindowGeometry after base.window (120, 60)
          assertBystanders before after base.window
          oldPanes <- require (Tmux.panesForWindow before base.window)
          newPanes <- require (Tmux.panesForWindow after base.window)
          map (.ref) newPanes @?= map (.ref) oldPanes
          map (.ref) (filter (.active) newPanes) @?= map (.ref) (filter (.active) oldPanes)
        assertPaneGeometry before base.pane (89, 39)

  , testCase "window axes resize the linked physical window" $
      withLayout $ \fixture server base -> do
        before <- Tmux.capture server
        length (filter ((== base.window) . (.window)) (Tmux.windowLinks before)) @?= 2
        width <- dimension 100
        height <- dimension 40
        columns <- dimension 80
        rows <- dimension 30
        forM_ [(Tmux.ResizeWidth width, (100, 60)), (Tmux.ResizeHeight height, (100, 40)),
               (Tmux.ResizeBoth columns rows, (80, 30))] $ \(size, expected) -> do
          Tmux.resizeWindowWith (Tmux.MutationOptions 2) server base.window size
          after <- Tmux.capture server
          assertWindowGeometry after base.window expected
          assertBystanders before after base.window
          oldPanes <- require (Tmux.panesForWindow before base.window)
          newPanes <- require (Tmux.panesForWindow after base.window)
          map (.ref) newPanes @?= map (.ref) oldPanes
        option fixture base.window >>= (@?= "manual\n")
        assertWindowGeometry before base.window (120, 60)

  , testCase "oversized axes refuse without unzooming or partly resizing" $
      withLayout $ \fixture server base -> do
        configured fixture ["resize-pane", "-Z", "-t", paneTarget base.pane]
        before <- Tmux.capture server
        beforeOption <- option fixture base.window
        small <- dimension 50
        forM_ [10001, 2147483648, 10 ^ (100 :: Int)] $ \number -> do
          large <- dimension number
          forM_ [Tmux.resizePane server base.pane (Tmux.ResizeWidth large),
                 Tmux.resizePane server base.pane (Tmux.ResizeHeight large),
                 Tmux.resizePane server base.pane (Tmux.ResizeBoth small large),
                 Tmux.resizePane server base.pane (Tmux.ResizeBoth large small),
                 Tmux.resizeWindow server base.window (Tmux.ResizeWidth large),
                 Tmux.resizeWindow server base.window (Tmux.ResizeHeight large),
                 Tmux.resizeWindow server base.window (Tmux.ResizeBoth small large),
                 Tmux.resizeWindow server base.window (Tmux.ResizeBoth large small)] $ \request ->
            Tmux.tryTmux request >>= \case
              Left (ExceptionWithContext context (Tmux.InvalidMutationArgument _)) ->
                assertBool "invalid resize retained an operation" (null (Recovery.mutationRecoveries context))
              _ -> assertFailure "oversized resize reached the daemon"
        after <- Tmux.capture server
        geometry after @?= geometry before
        assertBystanders before after base.window
        native fixture ["display-message", "-p", "-t", paneTarget base.pane, "-F", "#{window_zoomed_flag}"] >>= (@?= "1\n")
        option fixture base.window >>= (@?= beforeOption)

  , testCase "foreign, closed and stale references cannot resize a bystander" $
      withLayout $ \fixture server base -> do
        width <- dimension 50
        before <- Tmux.capture server
        Tmux.withServer (config fixture) $ \other -> do
          let offlinePane = F.paneRef (F.fixtureOrigin "resize") (Tmux.paneId base.pane)
              offlineWindow = F.windowRef (F.fixtureOrigin "resize") (Tmux.windowId base.window)
          forM_ [Tmux.resizePane other base.pane (Tmux.ResizeWidth width),
                 Tmux.resizeWindow other base.window (Tmux.ResizeWidth width),
                 Tmux.resizePane server offlinePane (Tmux.ResizeWidth width),
                 Tmux.resizeWindow server offlineWindow (Tmux.ResizeWidth width)] $ \request ->
            Tmux.tryTmux request >>= \case
              Left (ExceptionWithContext _ (Tmux.InvalidTarget _)) -> pure ()
              _ -> assertFailure "foreign resize was admitted"
        closed <- Tmux.withServer (config fixture) pure
        forM_ [Tmux.resizePane closed base.pane (Tmux.ResizeWidth width),
               Tmux.resizeWindow closed base.window (Tmux.ResizeWidth width)] $ \request ->
          Tmux.tryTmux request >>= \case
            Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
            _ -> assertFailure "closed handle admitted resize"
        unchanged <- Tmux.capture server
        geometry unchanged @?= geometry before
        Tmux.killWindow server base.window
        removed <- Tmux.capture server
        forM_ [Tmux.resizePane server base.pane (Tmux.ResizeWidth width),
               Tmux.resizeWindow server base.window (Tmux.ResizeWidth width)] $ \request ->
          Tmux.tryTmux request >>= \case
            Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
            _ -> assertFailure "stale target was rebound"
        after <- Tmux.capture server
        geometry after @?= geometry removed

  , testCase "hook errors retain applied resizes and correlated recovery" $
      forM_ [True, False] $ \paneResize -> withLayout $ \fixture server base -> do
        width <- dimension 50
        withHook fixture paneResize "has-session -t =missing-resize-hook" $
          Tmux.tryTmux (performResize paneResize server base (Tmux.ResizeWidth width)) >>= \case
            Left (ExceptionWithContext context (Tmux.MutationAppliedWithErrors _)) -> do
              recovery <- one (Recovery.mutationRecoveries context)
              Recovery.mutationGeneration recovery @?= Tmux.serverGeneration server
              observed <- Recovery.awaitMutationRecovery recovery
              observed.logical.outcome @?= Just Recovery.Failed
              observed.logical.retained @?= False
              after <- Tmux.capture server
              if paneResize then assertPaneGeometry after base.pane (50, 39)
                else assertWindowGeometry after base.window (50, 60)
            _ -> assertFailure "resize hook error lost the applied outcome"

  , testCase "cancellation preserves its class and exact resize operation owner" $
      forM_ [True, False] $ \paneResize -> withLayout $ \fixture server base -> do
        width <- dimension 50
        withHook fixture paneResize "wait-for -S resize-entered ; wait-for resize-release" $
          flip finally (configured fixture ["wait-for", "-S", "resize-release"]) $
            withAsync (configured fixture ["wait-for", "resize-entered"]) $ \entered ->
              withAsync (tryWithContext @SomeException (performResize paneResize server base (Tmux.ResizeWidth width))) $ \worker -> do
                bounded (wait entered)
                after <- Tmux.capture server
                if paneResize then assertPaneGeometry after base.pane (50, 39)
                  else assertWindowGeometry after base.window (50, 60)
                throwTo (asyncThreadId worker) ThreadKilled
                bounded (wait worker) >>= \case
                  Left (ExceptionWithContext context problem) -> do
                    fromException @AsyncException problem @?= Just ThreadKilled
                    recovery <- one (Recovery.mutationRecoveries context)
                    Recovery.mutationGeneration recovery @?= Tmux.serverGeneration server
                    observed <- bounded (Recovery.awaitMutationRecovery recovery)
                    observed.nativeOwned @?= False
                    observed.workerOwned @?= False
                    observed.logical.outcome @?= Just Recovery.OutcomeUnknown
                    Recovery.detachMutationRecovery recovery >>= (@?= True)
                  Right () -> assertFailure "cancelled resize returned success"
  ]

withLayout :: (Fixture.Fixture -> Tmux.Server -> Creation.CreatedSession -> IO a) -> IO a
withLayout action = Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
  columns <- dimension 120
  rows <- dimension 60
  base <- Tmux.createSession server Creation.defaultSessionOptions
    {Creation.name = Just "resize-main", Creation.width = Just columns, Creation.height = Just rows,
      Creation.process = cat}
  withPane fixture base.pane $ do
    side <- dimension 30
    right <- Tmux.splitPane server (Creation.WindowSlot base.session base.windowIndex) base.pane
      Creation.defaultSplitOptions {Creation.direction = Creation.LeftRight,
        Creation.size = Creation.SplitCells side, Creation.selectPane = True, Creation.splitProcess = cat}
    withPane fixture right.pane $ do
      lower <- dimension 20
      below <- Tmux.splitPane server (Creation.WindowSlot base.session base.windowIndex) base.pane
        Creation.defaultSplitOptions {Creation.size = Creation.SplitCells lower, Creation.splitProcess = cat}
      withPane fixture below.pane $ do
        bystander <- Tmux.createWindow server (Creation.NextFree base.session)
          Creation.defaultWindowOptions {Creation.selectWindow = True, Creation.windowProcess = cat}
        withPane fixture bystander.pane $ do
          configured fixture ["link-window", "-d", "-s", windowTarget base.window, "-t", "fixture:7"]
          action fixture server base

cat :: Creation.InitialProcess
cat = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])

withPane :: Fixture.Fixture -> Tmux.PaneRef -> IO a -> IO a
withPane fixture pane action = do
  pid <- native fixture ["display-message", "-p", "-t", paneTarget pane, "-F", "#{pane_pid}"]
  Fixture.withTrackedPane (Lazy.fromStrict pid)
    (void (Fixture.command fixture ["kill-pane", "-t", paneTarget pane])) action

performResize :: Bool -> Tmux.Server -> Creation.CreatedSession -> Tmux.Resize -> IO ()
performResize True server base = Tmux.resizePane server base.pane
performResize False server base = Tmux.resizeWindow server base.window

assertPaneGeometry :: Tmux.Snapshot -> Tmux.PaneRef -> (Integer, Integer) -> Assertion
assertPaneGeometry snapshot ref expected = do
  pane <- require (Tmux.lookupPane snapshot ref)
  (Tmux.dimensionValue pane.width, Tmux.dimensionValue pane.height) @?= expected

assertWindowGeometry :: Tmux.Snapshot -> Tmux.WindowRef -> (Integer, Integer) -> Assertion
assertWindowGeometry snapshot ref expected = do
  window <- require (Tmux.lookupWindow snapshot ref)
  (Tmux.dimensionValue window.width, Tmux.dimensionValue window.height) @?= expected

assertBystanders :: Tmux.Snapshot -> Tmux.Snapshot -> Tmux.WindowRef -> Assertion
assertBystanders before after target = do
  forM_ [row | row <- Tmux.windows before, row.ref /= target] $ \window ->
    assertWindowGeometry after window.ref (Tmux.dimensionValue window.width, Tmux.dimensionValue window.height)
  forM_ [row | row <- Tmux.panes before, row.window /= target] $ \pane ->
    assertPaneGeometry after pane.ref (Tmux.dimensionValue pane.width, Tmux.dimensionValue pane.height)
  Tmux.windowLinks after @?= Tmux.windowLinks before

geometry :: Tmux.Snapshot -> ([(Tmux.WindowRef, Tmux.Dimension, Tmux.Dimension)], [(Tmux.PaneRef, Tmux.Dimension, Tmux.Dimension)])
geometry snapshot = ([(row.ref, row.width, row.height) | row <- Tmux.windows snapshot],
  [(row.ref, row.width, row.height) | row <- Tmux.panes snapshot])

option :: Fixture.Fixture -> Tmux.WindowRef -> IO Bytes.ByteString
option fixture window = native fixture ["show-options", "-wv", "-t", windowTarget window, "window-size"]

native :: Fixture.Fixture -> [String] -> IO Bytes.ByteString
native fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, errors) @?= (ExitSuccess, "")
  pure (Lazy.toStrict output)

configured :: Fixture.Fixture -> [String] -> Assertion
configured fixture arguments = native fixture arguments >>= (@?= "")

withHook :: Fixture.Fixture -> Bool -> String -> IO a -> IO a
withHook fixture paneResize hook = bracket_
  (configured fixture ["set-hook", "-g", name, hook])
  (configured fixture ["set-hook", "-gu", name])
  where name = if paneResize then "after-resize-pane" else "after-resize-window"

paneTarget :: Tmux.PaneRef -> String
paneTarget = Text.unpack . Tmux.renderPaneId . Tmux.paneId

windowTarget :: Tmux.WindowRef -> String
windowTarget = Text.unpack . Tmux.renderWindowId . Tmux.windowId

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}

dimension :: Integer -> IO Tmux.Dimension
dimension = require . Tmux.mkDimension

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "resize event did not arrive") pure

one :: [a] -> IO a
one [value] = pure value
one _ = fail "expected one value"

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure
