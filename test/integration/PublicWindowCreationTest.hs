module PublicWindowCreationTest (tests) where

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
import System.Exit (ExitCode (..))
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public creation and pane relocation"
  [ testCase "window placement returns fresh identities and actual link indices" $
      withBase $ \fixture server base -> do
        before <- Tmux.capture server
        created <- Tmux.createWindow server (Creation.NextFree base.session)
          windowOptions {Creation.windowLabel = Just "#{pid};"}
        withPane fixture created.pane $ do
          after <- Tmux.capture server
          length (Tmux.windows after) @?= length (Tmux.windows before) + 1
          window <- require (Tmux.lookupWindow after created.window)
          Tmux.labelBytes window.name @?= "#{pid};"
          (Tmux.dimensionValue window.width, Tmux.dimensionValue window.height) @?= (120, 60)
          assertBool "window reused an existing identity" (created.window /= base.window)
          assertLink after created
          vacant <- require (Tmux.mkWindowIndex 9)
          forM_ [Creation.Before, Creation.After] $ \relative -> do
            empty <- Tmux.createWindow server (relative (Creation.WindowSlot base.session vacant)) windowOptions
            withPane fixture empty.pane (empty.windowIndex @?= vacant)
          index <- require (Tmux.mkWindowIndex 4)
          placed <- Tmux.createWindow server (Creation.At (Creation.WindowSlot base.session index))
            windowOptions {Creation.selectWindow = True}
          withPane fixture placed.pane $ do
            selected <- Tmux.capture server
            placed.windowIndex @?= index
            links <- require (Tmux.linksForSession selected base.session)
            map (.window) (filter (.active) links) @?= [placed.window]
            inserted <- Tmux.createWindow server (Creation.Before (Creation.WindowSlot base.session index)) windowOptions
            withPane fixture inserted.pane $ do
              shifted <- Tmux.capture server
              inserted.windowIndex @?= index
              assertLink shifted inserted
              linksAfter <- require (Tmux.linksForSession shifted base.session)
              anchor <- one [link | link <- linksAfter, link.window == placed.window]
              Tmux.windowIndexValue anchor.index @?= 5
              following <- Tmux.createWindow server (Creation.After (Creation.WindowSlot base.session anchor.index)) windowOptions
              withPane fixture following.pane $ do
                Tmux.windowIndexValue following.windowIndex @?= 6
                Tmux.capture server >>= \fresh -> assertLink fresh following

  , testCase "occupied slots reject unless replacement is explicit" $
      withBase $ \fixture server base -> do
        let placement = Creation.At (slot base)
        rejected (Tmux.createWindow server placement windowOptions)
        replacement <- Tmux.createWindow server placement windowOptions {Creation.collision = Creation.ReplaceOccupied}
        withPane fixture replacement.pane $ do
          fresh <- Tmux.capture server
          assertLink fresh replacement
          assertBool "replacement retained the old window" (replacement.window /= base.window)
          case Tmux.lookupWindow fresh base.window of
            Left (Tmux.MissingWindow _) -> pure ()
            _ -> assertFailure "replacement did not remove the old window"

  , testCase "splitting an inactive explicit pane preserves the other selected pane" $
      withBase $ \fixture server base -> do
        cells <- require (Tmux.mkDimension 30)
        right <- Tmux.splitPane server (slot base) base.pane
          splitOptions {Creation.direction = Creation.LeftRight, Creation.size = Creation.SplitCells cells,
            Creation.selectPane = True}
        withPane fixture right.pane $ do
          below <- Tmux.splitPane server (slot base) base.pane
            splitOptions {Creation.size = Creation.SplitPercent 25}
          withPane fixture below.pane $ do
            fresh <- Tmux.capture server
            panes <- require (Tmux.panesForWindow fresh base.window)
            length panes @?= 3
            old <- require (Tmux.lookupPane fresh base.pane)
            side <- require (Tmux.lookupPane fresh right.pane)
            new <- require (Tmux.lookupPane fresh below.pane)
            Tmux.dimensionValue side.width @?= 30
            Tmux.dimensionValue old.width @?= 89
            (Tmux.dimensionValue old.height, Tmux.dimensionValue new.height) @?= (44, 15)
            new.width @?= old.width
            map (.ref) (filter (.active) panes) @?= [right.pane]
            below.window @?= base.window
            below.session @?= base.session
            assertLink fresh below

  , testCase "split context retains repeated links and rejects a mismatched slot" $
      withBase $ \fixture server base -> do
        index <- require (Tmux.mkWindowIndex 7)
        let target = Text.unpack (Tmux.renderSessionId (Tmux.sessionId base.session)) <> ":7"
        configured fixture ["link-window", "-s", windowTarget base.window, "-t", target]
        created <- Tmux.splitPane server (Creation.WindowSlot base.session index) base.pane splitOptions
        withPane fixture created.pane $ do
          created.windowIndex @?= index
          created.window @?= base.window
          other <- Tmux.createWindow server (Creation.NextFree base.session) windowOptions
          withPane fixture other.pane $ do
            before <- Tmux.capture server
            rejected (Tmux.splitPane server (slot other) base.pane splitOptions)
            after <- Tmux.capture server
            map (.ref) (Tmux.panes after) @?= map (.ref) (Tmux.panes before)

  , testCase "insertion after the maximum slot refuses before daemon effects" $
      withBase $ \fixture server base -> do
        index <- require (Tmux.mkWindowIndex 2147483647)
        upper <- Tmux.createWindow server (Creation.At (Creation.WindowSlot base.session index)) windowOptions
        withPane fixture upper.pane $ do
          before <- Tmux.capture server
          Tmux.tryTmux (Tmux.createWindow server (Creation.After (slot upper)) windowOptions) >>= \case
            Left (ExceptionWithContext context (Tmux.InvalidMutationArgument _)) ->
              assertBool "maximum-slot refusal retained creation" (null (Recovery.creationRecoveries context))
            _ -> assertFailure "maximum-slot insertion reached the daemon"
          after <- Tmux.capture server
          map (.ref) (Tmux.windows after) @?= map (.ref) (Tmux.windows before)
          (Tmux.serverInfo after).pid @?= (Tmux.serverInfo before).pid

  , testCase "foreign, stale and invalid targets have no creation effects" $
      withBase $ \fixture server base -> do
        Tmux.withServer (config fixture) $ \otherServer -> do
          before <- Tmux.capture otherServer
          session <- one [row | row <- Tmux.sessions before, Tmux.sessionId row.ref == Tmux.sessionId base.session]
          pane <- one [row | row <- Tmux.panes before, Tmux.paneId row.ref == Tmux.paneId base.pane]
          forM_ [Tmux.createWindow otherServer (Creation.NextFree base.session) windowOptions,
                 Tmux.splitPane otherServer (slot base) pane.ref splitOptions,
                 Tmux.splitPane otherServer (Creation.WindowSlot session.ref base.windowIndex) base.pane splitOptions] $ \request ->
            Tmux.tryTmux request >>= \case
              Left (ExceptionWithContext context Tmux.InvalidTarget) ->
                assertBool "foreign target retained creation" (null (Recovery.creationRecoveries context))
              _ -> assertFailure "foreign generation was admitted"
          after <- Tmux.capture otherServer
          map (.ref) (Tmux.panes after) @?= map (.ref) (Tmux.panes before)
        forM_ [Tmux.createWindow server (Creation.NextFree base.session)
                 windowOptions {Creation.windowLabel = Just (Tmux.labelFromBytes "bad\NULname")},
               Tmux.splitPane server (slot base) base.pane splitOptions {Creation.size = Creation.SplitPercent 0}] $ \request ->
          Tmux.tryTmux request >>= \case
            Left (ExceptionWithContext context (Tmux.InvalidMutationArgument _)) ->
              assertBool "invalid operands retained creation" (null (Recovery.creationRecoveries context))
            _ -> assertFailure "invalid creation operands were admitted"
        stale <- Tmux.createWindow server (Creation.NextFree base.session) windowOptions
        withPane fixture stale.pane $ do
          configured fixture ["kill-pane", "-t", paneTarget stale.pane]
          before <- Tmux.capture server
          rejected (Tmux.splitPane server (slot stale) stale.pane splitOptions)
          after <- Tmux.capture server
          map (.ref) (Tmux.panes after) @?= map (.ref) (Tmux.panes before)
        configured fixture ["kill-session", "-t", Text.unpack (Tmux.renderSessionId (Tmux.sessionId base.session))]
        before <- Tmux.capture server
        rejected (Tmux.createWindow server (Creation.NextFree base.session) windowOptions)
        after <- Tmux.capture server
        map (.ref) (Tmux.windows after) @?= map (.ref) (Tmux.windows before)

  , testCase "window and split cancellation retain exact historical receipts" $
      forM_ [False, True] $ \split -> withBase $ \fixture server base -> do
        before <- Tmux.capture server
        let hook = if split then "after-split-window" else "after-new-window"
            request = if split then Tmux.splitPane server (slot base) base.pane splitOptions
              else Tmux.createWindow server (Creation.NextFree base.session) windowOptions
        withHook fixture hook "wait-for -S creation-entered ; wait-for creation-release" $
          flip finally (configured fixture ["wait-for", "-S", "creation-release"]) $
            withAsync (configured fixture ["wait-for", "creation-entered"]) $ \entered ->
              withAsync (tryWithContext @SomeException request) $ \worker -> do
                bounded (wait entered)
                fresh <- Tmux.capture server
                added <- one [pane | pane <- Tmux.panes fresh, pane.ref `notElem` map (.ref) (Tmux.panes before)]
                withPane fixture added.ref $ do
                  throwTo (asyncThreadId worker) ThreadKilled
                  bounded (wait worker) >>= \case
                    Left (ExceptionWithContext context problem) -> do
                      fromException @AsyncException problem @?= Just ThreadKilled
                      recovery <- one (Recovery.creationRecoveries context)
                      created <- Recovery.creationReceipt recovery >>= maybe (fail "cancellation lost observed IDs") pure
                      created.pane @?= added.ref
                      assertLink fresh created
                      status <- bounded (Recovery.awaitCreationRecovery recovery)
                      status.logical.outcome @?= Just Recovery.OutcomeUnknown
                      Recovery.detachCreationRecovery recovery >>= (@?= True)
                    Right _ -> assertFailure "cancelled creation returned success"

  , testCase "destructive after-hooks leave reachable historical IDs" $
      forM_ [False, True] $ \split -> withBase $ \fixture server base -> do
        before <- Tmux.capture server
        let hook = if split then "after-split-window" else "after-new-window"
            destroy = if split then "kill-pane" else "kill-window"
            request = if split then Tmux.splitPane server (slot base) base.pane splitOptions
              else Tmux.createWindow server (Creation.NextFree base.session) windowOptions
        withHook fixture hook ("wait-for -S creation-entered ; wait-for creation-release ; " <> destroy) $
          flip finally (configured fixture ["wait-for", "-S", "creation-release"]) $
            withAsync (configured fixture ["wait-for", "creation-entered"]) $ \entered ->
              withAsync request $ \worker -> do
                bounded (wait entered)
                fresh <- Tmux.capture server
                added <- one [pane | pane <- Tmux.panes fresh, pane.ref `notElem` map (.ref) (Tmux.panes before)]
                withPane fixture added.ref $ do
                  configured fixture ["wait-for", "-S", "creation-release"]
                  created <- bounded (wait worker)
                  created.pane @?= added.ref
                  after <- Tmux.capture server
                  case Tmux.lookupPane after created.pane of
                    Left (Tmux.MissingPane _) -> pure ()
                    _ -> assertFailure "after-hook did not remove the created pane"
  , testCase "pane relocation moves a linked window's last pane and preserves the process" $
      forM_ [Tmux.movePane, Tmux.joinPane] $ \relocate ->
        withBase $ \fixture server base -> do
          destination <- Tmux.createWindow server (Creation.NextFree base.session) windowOptions
          alias <- Tmux.createSession server Creation.defaultSessionOptions
            {Creation.name = Just "linked-source", Creation.process = cat}
          withPane fixture destination.pane $ withPane fixture alias.pane $ do
            index <- require (Tmux.mkWindowIndex 5)
            let link = Tmux.WindowSlot alias.session index
            Tmux.linkWindow server (slot base) link
            snapshot <- Tmux.capture server
            source <- occurrence snapshot link base.pane
            target <- occurrence snapshot (slot destination) destination.pane
            pid <- paneProcess fixture base.pane
            relocate server source target Tmux.defaultPaneMoveOptions >>=
              (@?= Tmux.MoveAccepted base.pane (slot destination) destination.window)
            fresh <- Tmux.capture server
            moved <- occurrence fresh (slot destination) base.pane
            moved.pane.window @?= destination.window
            paneProcess fixture base.pane >>= (@?= pid)
            Tmux.lookupWindow fresh base.window @?= Left (Tmux.MissingWindow base.window)
            _ <- occurrence fresh (slot alias) alias.pane
            _ <- occurrence fresh (slot destination) destination.pane
            pure ()

  , testCase "pane relocation rejects a stale slot even when tmux could find its numeric name" $
      withBase $ \fixture server base -> do
        index <- require (Tmux.mkWindowIndex 4)
        movedIndex <- require (Tmux.mkWindowIndex 7)
        destination <- Tmux.createWindow server (Creation.At (Tmux.WindowSlot base.session index))
          windowOptions {Creation.windowLabel = Just "4"}
        withPane fixture destination.pane $ do
          snapshot <- Tmux.capture server
          source <- occurrence snapshot (slot base) base.pane
          stale <- occurrence snapshot (slot destination) destination.pane
          let session = Text.unpack (Tmux.renderSessionId (Tmux.sessionId base.session))
          configured fixture ["move-window", "-s", session <> ":4", "-t", session <> ":7"]
          Tmux.tryTmux (Tmux.movePane server source stale Tmux.defaultPaneMoveOptions) >>= \case
            Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
            _ -> assertFailure "relocation accepted a stale numeric slot"
          fresh <- Tmux.capture server
          _ <- occurrence fresh (slot base) base.pane
          _ <- occurrence fresh (Tmux.WindowSlot base.session movedIndex) destination.pane
          pure ()

  , testCase "pane relocation refuses the same pane without unzooming its window" $
      withBase $ \fixture server base -> do
        other <- Tmux.splitPane server (slot base) base.pane splitOptions
        withPane fixture other.pane $ do
          configured fixture ["resize-pane", "-Z", "-t", paneTarget base.pane]
          snapshot <- Tmux.capture server
          exact <- occurrence snapshot (slot base) base.pane
          Tmux.tryTmux (Tmux.joinPane server exact exact Tmux.defaultPaneMoveOptions) >>= \case
            Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument _)) -> pure ()
            _ -> assertFailure "relocation accepted its own pane"
          fresh <- Tmux.capture server
          zoomed <- require (Tmux.lookupWindow fresh base.window)
          assertBool "refusing the same pane changed zoom" zoomed.zoomed

  , testCase "pane relocation breaks out a split and transfers a sole pane's exact link" $
      forM_ [False, True] $ \sole -> withBase $ \fixture server base -> do
        alias <- Tmux.createSession server Creation.defaultSessionOptions
          {Creation.name = Just "break-destination", Creation.process = cat}
        withPane fixture alias.pane $ do
          sourceIndex <- require (Tmux.mkWindowIndex 2)
          destinationIndex <- require (Tmux.mkWindowIndex 5)
          let sourceSlot = Tmux.WindowSlot alias.session sourceIndex
              destinationSlot = Tmux.WindowSlot alias.session destinationIndex
          Tmux.linkWindow server (slot base) sourceSlot
          pane <- if sole then pure base.pane
            else (.pane) <$> Tmux.splitPane server sourceSlot base.pane splitOptions
          withPane fixture pane $ do
            snapshot <- Tmux.capture server
            exact <- occurrence snapshot sourceSlot pane
            pid <- paneProcess fixture pane
            Tmux.breakPane server exact destinationSlot >>= \case
              Tmux.BreakAccepted reported requested _ -> do
                reported @?= pane
                requested @?= destinationSlot
              _ -> assertFailure "expected a break-pane receipt"
            fresh <- Tmux.capture server
            relocated <- occurrence fresh destinationSlot pane
            (relocated.pane.window == base.window) @?= sole
            paneProcess fixture pane >>= (@?= pid)
            _ <- occurrence fresh (slot base) base.pane
            links <- require (Tmux.linksForSession fresh alias.session)
            any (\link -> link.index == sourceIndex && link.window == base.window) links @?= not sole

  ]

windowOptions :: Creation.WindowOptions
windowOptions = Creation.defaultWindowOptions {Creation.windowProcess = cat}

splitOptions :: Creation.SplitOptions
splitOptions = Creation.defaultSplitOptions {Creation.splitProcess = cat}

cat :: Creation.InitialProcess
cat = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])

slot :: Creation.CreatedEntities -> Creation.WindowSlot
slot created = Creation.WindowSlot created.session created.windowIndex

withBase :: (Fixture.Fixture -> Tmux.Server -> Creation.CreatedSession -> IO a) -> IO a
withBase action = Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
  columns <- require (Tmux.mkDimension 120)
  rows <- require (Tmux.mkDimension 60)
  base <- Tmux.createSession server Creation.defaultSessionOptions
    {Creation.name = Just "window-core", Creation.width = Just columns, Creation.height = Just rows,
      Creation.process = cat}
  withPane fixture base.pane (action fixture server base)

withPane :: Fixture.Fixture -> Tmux.PaneRef -> IO a -> IO a
withPane fixture pane action = do
  pid <- paneProcess fixture pane
  Fixture.withTrackedPane pid (void (Fixture.command fixture ["kill-pane", "-t", paneTarget pane])) action

paneProcess :: Fixture.Fixture -> Tmux.PaneRef -> IO Lazy.ByteString
paneProcess fixture pane = do
  (code, pid, errors) <- Fixture.command fixture ["display-message", "-p", "-t", paneTarget pane, "-F", "#{pane_pid}"]
  (code, errors) @?= (ExitSuccess, "")
  pure pid

occurrence :: Tmux.Snapshot -> Tmux.WindowSlot -> Tmux.PaneRef -> IO Tmux.PaneOccurrence
occurrence snapshot (Tmux.WindowSlot session index) pane =
  one [entry | entry <- Tmux.paneOccurrences snapshot,
    entry.link.session == session, entry.link.index == index, entry.pane.ref == pane]

assertLink :: Tmux.Snapshot -> Creation.CreatedEntities -> Assertion
assertLink snapshot created = do
  links <- require (Tmux.linksForSession snapshot created.session)
  map (.window) (filter (\link -> link.index == created.windowIndex) links) @?= [created.window]
  pane <- require (Tmux.lookupPane snapshot created.pane)
  pane.window @?= created.window
  created.serverPid @?= (Tmux.serverInfo snapshot).pid

paneTarget :: Tmux.PaneRef -> String
paneTarget = Text.unpack . Tmux.renderPaneId . Tmux.paneId

windowTarget :: Tmux.WindowRef -> String
windowTarget = Text.unpack . Tmux.renderWindowId . Tmux.windowId

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}

withHook :: Fixture.Fixture -> String -> String -> IO a -> IO a
withHook fixture name hook = bracket_
  (configured fixture ["set-hook", "-g", name, hook])
  (configured fixture ["set-hook", "-gu", name])

configured :: Fixture.Fixture -> [String] -> Assertion
configured fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, output, errors) @?= (ExitSuccess, "", "")

rejected :: IO a -> Assertion
rejected action = Tmux.tryTmux action >>= \case
  Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
  _ -> assertFailure "native creation was not rejected"

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "creation event did not arrive") pure

one :: [a] -> IO a
one [value] = pure value
one _ = fail "expected one value"

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure
