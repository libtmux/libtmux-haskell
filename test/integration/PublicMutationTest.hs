module PublicMutationTest (tests) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Exception
  ( AsyncException (..), ExceptionWithContext (..), SomeException, finally
  , fromException, throwTo, tryWithContext
  )
import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as Text
import Fixture qualified
import LibTmux qualified as Tmux
import LibTmux.Snapshot.Fixture qualified as F
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public mutation API"
  [ testCase "renames physical entities and keeps the old snapshot detached" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        configured fixture ["select-pane", "-t", "%0", "-T", "original-title"]
        configured fixture ["link-window", "-s", "@0", "-t", "fixture:3"]
        Tmux.withServer (config fixture) $ \server -> do
          before <- Tmux.capture server
          session <- one (Tmux.sessions before)
          window <- one (Tmux.windows before)
          pane <- one (Tmux.panes before)
          Tmux.renameSession server session.ref "renamed-#{pid};"
          Tmux.renameWindow server window.ref "api #{pid};"
          Tmux.setPaneTitle server pane.ref "editor #{pid};"
          after <- Tmux.capture server
          newerSession <- require (Tmux.lookupSession after session.ref)
          newerWindow <- require (Tmux.lookupWindow after window.ref)
          newerPane <- require (Tmux.lookupPane after pane.ref)
          newerSession.name @?= "renamed-#{pid};"
          newerWindow.name @?= "api #{pid};"
          newerPane.title @?= "editor #{pid};"
          length (Tmux.windows after) @?= 1
          length (Tmux.windowLinks after) @?= 2
          forM_ (Tmux.windowLinks after) $ \link -> do
            observed <- require (Tmux.lookupWindow after link.window)
            observed.name @?= "api #{pid};"
          oldSession <- require (Tmux.lookupSession before session.ref)
          oldWindow <- require (Tmux.lookupWindow before window.ref)
          oldPane <- require (Tmux.lookupPane before pane.ref)
          oldSession.name @?= "fixture"
          oldWindow.name @?= "original-window"
          oldPane.title @?= "original-title"

  , testCase "links and selects explicit slots and preserves exact panes when tiling" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        configured fixture ["split-window", "-h", "-d", "-t", "fixture:0", "/bin/cat", "-"]
        configured fixture ["new-window", "-d", "-t", "fixture:7", "/bin/cat", "-"]
        originalIndex <- require (Tmux.mkWindowIndex 0)
        duplicateIndex <- require (Tmux.mkWindowIndex 4)
        unrelatedIndex <- require (Tmux.mkWindowIndex 7)
        before <- Tmux.capture server
        session <- one (Tmux.sessions before)
        links <- require (Tmux.linksForSession before session.ref)
        original <- one [link | link <- links, link.index == originalIndex]
        unrelated <- one [link | link <- links, link.index == unrelatedIndex]
        unrelatedWindow <- require (Tmux.lookupWindow before unrelated.window)
        panes <- require (Tmux.panesForWindow before original.window)
        target <- one (filter (not . (.active)) panes)
        let source = Tmux.WindowSlot session.ref originalIndex
            duplicate = Tmux.WindowSlot session.ref duplicateIndex
            unrelatedSlot = Tmux.WindowSlot session.ref unrelatedIndex

        Tmux.linkWindow server source duplicate
        linked <- Tmux.capture server
        linkedSlots <- require (Tmux.linksForSession linked session.ref)
        map (.index) (filter ((== original.window) . (.window)) linkedSlots)
          @?= [originalIndex, duplicateIndex]
        map (.index) (filter (.active) linkedSlots) @?= [originalIndex]
        Tmux.tryTmux (Tmux.linkWindow server source unrelatedSlot) >>= \case
          Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
          _ -> assertFailure "linking replaced an occupied slot"

        Tmux.selectWindowLink server duplicate
        Tmux.selectExactPane server duplicate target.ref
        Tmux.tryTmux (Tmux.selectExactPane server unrelatedSlot target.ref) >>= \case
          Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
          _ -> assertFailure "pane selection accepted the wrong window slot"
        Tmux.selectLayout server duplicate Tmux.Tiled
        tiled <- Tmux.capture server
        tiledSlots <- require (Tmux.linksForSession tiled session.ref)
        map (.index) (filter (.active) tiledSlots) @?= [duplicateIndex]
        tiledPanes <- require (Tmux.panesForWindow tiled original.window)
        map (.ref) (filter (.active) tiledPanes) @?= [target.ref]
        map (.ref) tiledPanes @?= map (.ref) panes
        assertBool "tiled did not change the original side-by-side geometry"
          (and (zipWith (\old new -> new.width > old.width && new.height < old.height) panes tiledPanes))
        Tmux.lookupWindow tiled unrelated.window @?= Right unrelatedWindow

        Tmux.unlinkWindow server duplicate
        remaining <- Tmux.capture server
        remainingSlots <- require (Tmux.linksForSession remaining session.ref)
        map (.index) (filter ((== original.window) . (.window)) remainingSlots) @?= [originalIndex]
        require (Tmux.panesForWindow remaining original.window) >>= (@?= map (.ref) tiledPanes) . map (.ref)
        Tmux.tryTmux (Tmux.unlinkWindow server source) >>= \case
          Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
          _ -> assertFailure "unlink removed the physical window's last link"
        Tmux.withServer (config fixture) $ \other -> do
          sameEndpoint <- Tmux.capture other
          otherSession <- one (Tmux.sessions sameEndpoint)
          Tmux.tryTmux (Tmux.linkWindow server source (Tmux.WindowSlot otherSession.ref duplicateIndex))
            >>= expectInvalidTarget

  , testCase "kills only the selected pane, physical window and session" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["new-session", "-d", "-s", "disposable", "/bin/cat", "-"]
        configured fixture ["new-window", "-d", "-t", "disposable:4", "-n", "shared", "/bin/cat", "-"]
        configured fixture ["split-window", "-d", "-t", "disposable:4", "/bin/cat", "-"]
        configured fixture ["link-window", "-s", "disposable:4", "-t", "fixture:4"]
        Tmux.withServer (config fixture) $ \server -> do
          before <- Tmux.capture server
          session <- one [row | row <- Tmux.sessions before, row.name == "disposable"]
          bystander <- one [row | row <- Tmux.sessions before, row.name == "fixture"]
          window <- one [row | row <- Tmux.windows before, row.name == "shared"]
          panes <- require (Tmux.panesForWindow before window.ref)
          pane <- one (filter (not . (.active)) panes)
          sibling <- one (filter (.active) panes)
          length [link | link <- Tmux.windowLinks before, link.window == window.ref] @?= 2

          Tmux.killPane server pane.ref
          afterPane <- Tmux.capture server
          Tmux.lookupPane afterPane pane.ref @?= Left (Tmux.MissingPane pane.ref)
          require (Tmux.panesForWindow afterPane window.ref) >>= (@?= [sibling.ref]) . map (.ref)
          Tmux.tryTmux (Tmux.killPane server pane.ref) >>= \case
            Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
            _ -> assertFailure "removed pane was accepted as a live target"

          Tmux.killWindow server window.ref
          afterWindow <- Tmux.capture server
          Tmux.lookupWindow afterWindow window.ref @?= Left (Tmux.MissingWindow window.ref)
          Tmux.lookupPane afterWindow sibling.ref @?= Left (Tmux.MissingPane sibling.ref)
          length (Tmux.sessions afterWindow) @?= 2
          assertBool "a link to the killed physical window survived"
            (all ((/= window.ref) . (.window)) (Tmux.windowLinks afterWindow))

          Tmux.killSession server session.ref
          afterSession <- Tmux.capture server
          Tmux.lookupSession afterSession session.ref @?= Left (Tmux.MissingSession session.ref)
          map (.ref) (Tmux.sessions afterSession) @?= [bystander.ref]

  , testCase "sends literal text and a named key to one pane" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        before <- Tmux.capture server
        bystander <- one (Tmux.panes before)
        let application = unlines
              [ "set -eu"
              , "stty -icanon -echo icrnl min 1 time 0"
              , "signal() { \"$1\" -N -S \"$2\" wait-for -S \"$3\"; }"
              , "signal \"$2\" \"$3\" input-ready"
              , "dd bs=1 count=5 status=none of=\"$1/literal-input\""
              , "signal \"$2\" \"$3\" input-literal"
              , "dd bs=1 count=1 status=none of=\"$1/named-input\""
              , "signal \"$2\" \"$3\" input-named"
              , "exec /bin/cat -"
              ]
            await signal = bounded (configured fixture ["wait-for", signal])
        configured fixture ["split-window", "-d", "/bin/sh", "-c", application,
          "sh", fixture.directory, fixture.executable, fixture.socket]
        await "input-ready"
        split <- Tmux.capture server
        target <- one [pane | pane <- Tmux.panes split, pane.ref /= bystander.ref]
        Tmux.withServer (config fixture) $ \other ->
          Tmux.tryTmux (Tmux.sendKeys other target.ref (Tmux.LiteralText "wrong")) >>= expectInvalidTarget
        Tmux.tryTmux (Tmux.sendKeys server target.ref (Tmux.NamedKeys ("Enter" :| ["invalid-key-name"]))) >>= \case
          Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument _)) -> pure ()
          _ -> assertFailure "partly invalid key sequence was admitted"

        Tmux.sendKeys server target.ref (Tmux.LiteralText "Enter")
        await "input-literal"
        Bytes.readFile (fixture.directory </> "literal-input") >>= (@?= "Enter")
        Tmux.sendKeys server target.ref (Tmux.NamedKeys ("Enter" :| []))
        await "input-named"
        Bytes.readFile (fixture.directory </> "named-input") >>= (@?= "\n")
        (code, screen, diagnostic) <- Fixture.command fixture
          ["capture-pane", "-p", "-t", Text.unpack (Tmux.renderPaneId (Tmux.paneId bystander.ref))]
        (code, diagnostic) @?= (ExitSuccess, "")
        assertBool "bystander received input" (all Lazy.null (Lazy.lines screen))
        Tmux.killPane server target.ref

  , testCase "captures bounded plain and styled text from an explicit pane" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        before <- Tmux.capture server
        bystander <- one (Tmux.panes before)
        let application = unlines
              [ "set -eu"
              , "printf 'caf\\033[31m\\303\\251\\033[0m\\n\\n%%end 12 34 0\\n\\n'"
              , "\"$1\" -N -S \"$2\" wait-for -S capture-visible"
              , "\"$1\" -N -S \"$2\" wait-for capture-more"
              , "i=0; while [ \"$i\" -lt 48 ]; do printf 'row %02d\\n' \"$i\"; i=$((i+1)); done"
              , "\"$1\" -N -S \"$2\" wait-for -S capture-history"
              , "exec /bin/cat -"
              ]
        configured fixture ["split-window", "-d", "/bin/sh", "-c", application,
          "sh", fixture.executable, fixture.socket]
        bounded (configured fixture ["wait-for", "capture-visible"])
        observed <- Tmux.capture server
        target <- one [pane | pane <- Tmux.panes observed, pane.ref /= bystander.ref]
        configured fixture ["set-hook", "-g", "after-capture-pane",
          "display-message -p libtmux-unrelated-hook-output"]

        plain <- Tmux.paneText <$> Tmux.capturePane server target.ref Tmux.defaultPaneCapture
        assertBool "plain text lost Unicode, blanks or the control-shaped line"
          ("café\n\n%end 12 34 0\n" `Text.isPrefixOf` plain)
        assertBool "hook output contaminated the capture"
          (not ("libtmux-unrelated-hook-output" `Text.isInfixOf` plain))
        let styledOptions = Tmux.defaultPaneCapture {Tmux.rendering = Tmux.AnsiStyled}
        styled <- Tmux.paneText <$> Tmux.capturePane server target.ref styledOptions
        assertBool "styled text lost the color change inside café"
          ("caf\ESC[31mé" `Text.isPrefixOf` styled)
        bystanderText <- Tmux.paneText <$> Tmux.capturePane server bystander.ref Tmux.defaultPaneCapture
        assertBool "selected pane was confused with its bystander" (Text.all (== '\n') bystanderText)

        let tiny = Tmux.defaultPaneCapture {Tmux.byteLimit = 4}
        Tmux.tryTmux (Tmux.capturePane server target.ref tiny) >>= \case
          Left (ExceptionWithContext _ (Tmux.PaneTextTooLarge 4)) -> pure ()
          _ -> assertFailure "the byte limit did not refuse this capture"
        configured fixture ["wait-for", "-S", "capture-more"]
        bounded (configured fixture ["wait-for", "capture-history"])
        let history = Tmux.defaultPaneCapture {Tmux.rows = Tmux.RowsBetween (-3) (-1)}
        previous <- Tmux.paneText <$> Tmux.capturePane server target.ref history
        length (Text.lines previous) @?= 3
        assertBool "history rows did not come from the pane" (all (Text.isPrefixOf "row ") (Text.lines previous))
        configured fixture ["set-hook", "-g", "after-capture-pane", "display-message -p -d invalid-duration"]
        flip finally (configured fixture ["set-hook", "-gu", "after-capture-pane"]) $
          Tmux.tryTmux (Tmux.capturePane server target.ref Tmux.defaultPaneCapture) >>= \case
            Left (ExceptionWithContext _ (Tmux.PaneCaptureHookFailed diagnostic)) ->
              assertBool "hook diagnostic lost" ("delay invalid" `Bytes.isInfixOf` diagnostic)
            _ -> assertFailure "capture hook failure lost its outcome"
        Tmux.killPane server target.ref
        Tmux.tryTmux (Tmux.capturePane server target.ref Tmux.defaultPaneCapture) >>= \case
          Left (ExceptionWithContext _ (Tmux.PaneCaptureRejected _)) -> pure ()
          _ -> assertFailure "a vanished pane was accepted"

  , testCase "waits for new pane text with witnessed freshness and retains the last capture" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        let run = configured fixture
            await event = bounded (run ["wait-for", event])
            application = unlines
              [ "set -eu"
              , "stty -echo"
              , "signal() { \"$1\" -N -S \"$2\" wait-for -S \"$3\"; }"
              , "printf 'READY\\n'"
              , "signal \"$1\" \"$2\" text-wait-ready"
              , "while IFS= read -r action; do"
              , "  case \"$action\" in"
              , "    edit) printf '\\033[2J\\033[Hchanged\\nREADY\\n' ;;"
              , "    add) printf 'READY\\n' ;;"
              , "    clear) printf '\\033[2J\\033[Hwaiting\\n' ;;"
              , "    show) printf 'READY\\n' ;;"
              , "    finish) exit 0 ;;"
              , "  esac"
              , "  signal \"$1\" \"$2\" text-wait-written"
              , "done"
              ]
        earlier <- Tmux.capture server
        bystander <- one (Tmux.panes earlier)
        run ["split-window", "-d", "/bin/sh", "-c", application, "sh", fixture.executable, fixture.socket]
        await "text-wait-ready"
        observed <- Tmux.capture server
        target <- one [pane.ref | pane <- Tmux.panes observed, pane.ref /= bystander.ref]
        let readText = Tmux.capturePane server target Tmux.defaultPaneCapture
            update action = do
              Tmux.sendKeys server target (Tmux.LiteralText action)
              Tmux.sendKeys server target (Tmux.NamedKeys ("Enter" :| []))
              await "text-wait-written"
            waitText = \options -> Tmux.waitForText server target options "READY"
            checkMatched expected result = case result of
              Tmux.PaneTextMatched value ->
                Text.count "READY" (Tmux.paneText value) @?= expected
              _ -> assertFailure "expected a pane text match"
        baseline <- readText
        let transition action = do
              let captured = "text-wait-read-" <> Text.unpack action
              run ["set-hook", "-g", "after-capture-pane", "wait-for -S " <> captured]
              flip finally (run ["set-hook", "-gu", "after-capture-pane"]) $
                withAsync (waitText fresh) $ \worker -> do
                  await captured
                  update action
                  bounded (wait worker)
            fresh = Tmux.defaultPaneWait {Tmux.waitMatch = Tmux.FreshSince baseline}
        waitText Tmux.defaultPaneWait >>= checkMatched 1

        update "edit"
        waitText (fresh {Tmux.waitTimeout = 0.16}) >>= \case
          Tmux.PaneTextTimedOut (Just latest) Nothing ->
            assertBool "deadline did not retain the moved old occurrence"
              ("changed\nREADY\n" `Text.isPrefixOf` Tmux.paneText latest)
          _ -> assertFailure "an unrelated edit or moved old text ended the wait"

        transition "add" >>= checkMatched 2
        update "clear"
        absent <- readText
        assertBool "expected a baseline without READY" (not ("READY" `Text.isInfixOf` Tmux.paneText absent))
        transition "show" >>= checkMatched 1
        waitText (fresh {Tmux.waitMatch = Tmux.FreshSince absent}) >>= checkMatched 1

        let otherRendering = Tmux.defaultPaneCapture {Tmux.rendering = Tmux.AnsiStyled}
        Tmux.tryTmux (waitText (fresh {Tmux.waitCapture = otherRendering})) >>= \case
          Left (ExceptionWithContext _ (Tmux.InvalidConfiguration _)) -> pure ()
          _ -> assertFailure "wait admitted a baseline with a different rendering"
        Tmux.withServer (config fixture) $ \other ->
          Tmux.tryTmux (Tmux.waitForText other target Tmux.defaultPaneWait "READY") >>= \case
            Left (ExceptionWithContext _ (Tmux.InvalidTarget _)) -> pure ()
            _ -> assertFailure "wait admitted a foreign PaneRef"

        run ["set-hook", "-g", "pane-died", "wait-for -S text-wait-exited"]
        run ["set-option", "-gw", "remain-on-exit", "on"]
        Tmux.sendKeys server target (Tmux.LiteralText "finish")
        Tmux.sendKeys server target (Tmux.NamedKeys ("Enter" :| []))
        await "text-wait-exited"
        Tmux.waitForText server target Tmux.defaultPaneWait "never-sent" >>= \case
          Tmux.PaneTextExited (Just _) -> pure ()
          _ -> assertFailure "a retained dead pane did not end the wait"
        Tmux.killPane server target
        Tmux.waitForText server target Tmux.defaultPaneWait "never-sent" >>= \case
          Tmux.PaneTextExited Nothing -> pure ()
          _ -> assertFailure "a removed pane did not end the wait"

  , testCase "cancelling a pane text wait retains its blocked capture owner" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        snapshot <- Tmux.capture server
        pane <- one (Tmux.panes snapshot)
        let run = configured fixture
            release = do
              run ["wait-for", "-S", "text-wait-release"]
              run ["set-hook", "-gu", "after-capture-pane"]
        run ["set-hook", "-g", "after-capture-pane",
          "wait-for -S text-wait-blocked ; wait-for text-wait-release"]
        flip finally release $
          withAsync (run ["wait-for", "text-wait-blocked"]) $ \entered ->
            withAsync (tryWithContext @SomeException
              (Tmux.waitForText server pane.ref Tmux.defaultPaneWait "not-present")) $ \worker -> do
                bounded (wait entered)
                throwTo (asyncThreadId worker) ThreadKilled
                bounded (wait worker) >>= \case
                  Left (ExceptionWithContext context problem) -> do
                    fromException @AsyncException problem @?= Just ThreadKilled
                    case Tmux.captureRecoveries context of
                      [recovery] -> do
                        Tmux.recoveryGeneration recovery @?= Tmux.serverGeneration server
                        release
                        Tmux.resumeCaptureRecovery recovery
                        _ <- Tmux.detachCaptureRecovery recovery
                        pure ()
                      _ -> assertFailure "cancelled text wait lost its exact capture owner"
                  Right _ -> assertFailure "cancelled text wait returned a result"

  , testCase "observes exact environment bytes and distinguishes empty, removed and absent" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        snapshot <- Tmux.capture server
        session <- one (Tmux.sessions snapshot)
        let name = "-LIBTMUX_EXACT_ENVIRONMENT"
            value = "caf" <> Bytes.singleton '\255' <> "\nvalue=\"#{pid};\\\n"
            global = Tmux.GlobalEnvironment
            local = Tmux.SessionEnvironment session.ref
            readEntry scope = Tmux.getEnvironment server scope name
            expect label expected action = do
              actual <- action
              assertBool label (actual == expected)
        expect "unknown global variable was present" Nothing (readEntry global)
        Tmux.setEnvironment server global name Tmux.Visible ""
        expect "global empty value was lost" (Just (Tmux.EnvironmentValue Tmux.Visible "")) (readEntry global)
        expect "session lookup implicitly read the global entry" Nothing (readEntry local)

        configured fixture ["set-hook", "-g", "after-show-environment", "display-message -p environment-hook-noise"]
        Tmux.setEnvironment server local name Tmux.Hidden value
        expect "hidden value bytes changed" (Just (Tmux.EnvironmentValue Tmux.Hidden value)) (readEntry local)
        Tmux.markEnvironmentRemoved server local name
        expect "the removal marker lost hidden visibility" (Just (Tmux.EnvironmentRemoved Tmux.Hidden)) (readEntry local)
        Tmux.unsetEnvironment server local name
        expect "unset left a session entry" Nothing (readEntry local)
        Tmux.setEnvironment server local name Tmux.Visible "literal #{pid};"
        expect "variable value was formatted or lost its semicolon"
          (Just (Tmux.EnvironmentValue Tmux.Visible "literal #{pid};")) (readEntry local)
        Tmux.unsetEnvironment server global name
        expect "global unset left an entry" Nothing (readEntry global)
        expect "global unset changed the session entry"
          (Just (Tmux.EnvironmentValue Tmux.Visible "literal #{pid};")) (readEntry local)

        Tmux.tryTmux (Tmux.setEnvironment server local "bad=name" Tmux.Visible "ignored") >>= \case
          Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument _)) -> pure ()
          _ -> assertFailure "invalid environment name reached tmux"
        configured fixture ["new-session", "-d", "-s", "temporary-environment", "/bin/cat", "-"]
        expanded <- Tmux.capture server
        temporary <- one [row | row <- Tmux.sessions expanded, row.name == "temporary-environment"]
        Tmux.killSession server temporary.ref
        Tmux.tryTmux (readEntry (Tmux.SessionEnvironment temporary.ref)) >>= \case
          Left (ExceptionWithContext _ (Tmux.EnvironmentReadRejected _)) -> pure ()
          _ -> assertFailure "missing session was reported as absent variable"

  , testCase "round-trips binary named buffers and pastes with an explicit newline policy" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        let run = configured fixture
            await event = bounded (run ["wait-for", event])
            name = "libtmux-exact-binary"
            payload = "raw\NUL" <> Bytes.singleton '\255' <> "\n"
            application = unlines
              [ "set -eu"
              , "stty raw -echo"
              , "signal() { \"$1\" -N -S \"$2\" wait-for -S \"$3\"; }"
              , "signal \"$1\" \"$2\" buffer-paste-ready"
              , "dd bs=1 count=6 status=none of=\"$3/paste-lf\""
              , "signal \"$1\" \"$2\" buffer-paste-lf"
              , "dd bs=1 count=6 status=none of=\"$3/paste-cr\""
              , "signal \"$1\" \"$2\" buffer-paste-cr"
              , "exec /bin/cat -"
              ]
        snapshot <- Tmux.capture server
        bystander <- one (Tmux.panes snapshot)
        run ["split-window", "-d", "/bin/sh", "-c", application, "sh",
          fixture.executable, fixture.socket, fixture.directory]
        await "buffer-paste-ready"
        observed <- Tmux.capture server
        target <- one [pane | pane <- Tmux.panes observed, pane.ref /= bystander.ref]

        run ["set-hook", "-g", "after-load-buffer", "display-message -p buffer-load-hook"]
        run ["set-hook", "-g", "after-save-buffer", "display-message -p buffer-save-hook"]
        Tmux.loadBuffer server name payload
        Tmux.readBuffer server name >>= (@?= payload)
        Tmux.pasteBuffer server target.ref name Tmux.PreserveLineFeeds
        await "buffer-paste-lf"
        Bytes.readFile (fixture.directory </> "paste-lf") >>= (@?= payload)
        Tmux.pasteBuffer server target.ref name Tmux.LineFeedsToCarriageReturns
        await "buffer-paste-cr"
        Bytes.readFile (fixture.directory </> "paste-cr") >>= (@?= Bytes.init payload <> "\r")
        unchanged <- Tmux.capturePane server bystander.ref Tmux.defaultPaneCapture
        assertBool "buffer paste changed a different pane" (Text.all (== '\n') (Tmux.paneText unchanged))

        let largeFile = fixture.directory </> "large-native-buffer"
        Bytes.writeFile largeFile (Bytes.replicate 65537 'x')
        run ["set-hook", "-gu", "after-load-buffer"]
        run ["load-buffer", "-b", "libtmux-large-binary", largeFile]
        Tmux.tryTmux (Tmux.readBuffer server "libtmux-large-binary") >>= \case
          Left (ExceptionWithContext _ (Tmux.BufferTooLarge 65536)) -> pure ()
          _ -> assertFailure "oversized native buffer did not give a bounded refusal"
        Tmux.tryTmux (Tmux.readBuffer server "libtmux-absent-binary") >>= \case
          Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
          _ -> assertFailure "missing exact buffer was accepted"
        Tmux.readBuffer server name >>= (@?= payload)

  , testCase "refuses foreign and offline references before changing the daemon" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime (config fixture) $ \first -> do
          snapshot <- Tmux.capture first
          window <- one (Tmux.windows snapshot)
          Tmux.withServerIn runtime (config fixture) $ \other -> do
            rejected <- Tmux.tryTmux (Tmux.renameWindow other window.ref "foreign-write")
            expectInvalidTarget rejected
            Tmux.tryTmux (Tmux.killWindow other window.ref) >>= expectInvalidTarget
            let offline = F.windowRef (F.fixtureOrigin "test") (Tmux.windowId window.ref)
            Tmux.tryTmux (Tmux.renameWindow other offline "fixture-write") >>= expectInvalidTarget
          after <- Tmux.capture first
          observed <- require (Tmux.lookupWindow after window.ref)
          observed.name @?= "original-window"

  , testCase "closed handles reject before dispatch" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        (closed, ref) <- Tmux.withServer (config fixture) $ \server -> do
          snapshot <- Tmux.capture server
          window <- one (Tmux.windows snapshot)
          pure (server, window.ref)
        Tmux.tryTmux (Tmux.renameWindow closed ref "closed-write") >>= \case
          Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
          _ -> assertFailure "closed handle admitted a mutation"

  , testCase "invalid timeouts and NUL operands reject before dispatch" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        Tmux.withServer (config fixture) $ \server -> do
          snapshot <- Tmux.capture server
          window <- one (Tmux.windows snapshot)
          forM_ [0, -1, 11] $ \duration -> do
            let options = Tmux.defaultMutationOptions {Tmux.timeout = duration}
            Tmux.tryTmux (Tmux.renameWindowWith options server window.ref "invalid-deadline") >>= \case
              Left (ExceptionWithContext _ (Tmux.InvalidConfiguration _)) -> pure ()
              _ -> assertFailure "invalid timeout admitted a mutation"
          Tmux.tryTmux (Tmux.renameWindow server window.ref (Tmux.labelFromBytes "x\NULy")) >>= \case
            Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument _)) -> pure ()
            _ -> assertFailure "invalid operand admitted a mutation"
          after <- Tmux.capture server
          observed <- require (Tmux.lookupWindow after window.ref)
          observed.name @?= "original-window"

  , testCase "reports an applied hook error separately from a missing pane" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        snapshot <- Tmux.capture server
        window <- one (Tmux.windows snapshot)
        pane <- one (Tmux.panes snapshot)
        configured fixture ["set-hook", "-g", "after-rename-window", "has-session -t =libtmux-missing"]
        flip finally (configured fixture ["set-hook", "-gu", "after-rename-window"]) $ do
          Tmux.tryTmux (Tmux.renameWindow server window.ref "applied-before-hook-error") >>= \case
            Left (ExceptionWithContext context (Tmux.MutationAppliedWithErrors _)) ->
              case Tmux.mutationRecoveries context of
                [recovery] -> do
                  observed <- Tmux.inspectMutationRecovery recovery
                  observed.logical.outcome @?= Just Tmux.Failed
                  observed.logical.retained @?= False
                  Tmux.operationStatus (Tmux.mutationOperation recovery) >>= (@?= observed.logical)
                _ -> assertFailure "known failure lost its correlated status"
            _ -> assertFailure "applied hook failure lost its outcome"
          after <- Tmux.capture server
          changed <- require (Tmux.lookupWindow after window.ref)
          changed.name @?= "applied-before-hook-error"
        configured fixture ["kill-pane", "-t", "%0"]
        Tmux.tryTmux (Tmux.setPaneTitle server pane.ref "disappeared") >>= \case
          Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
          _ -> assertFailure "disappeared pane did not reject its command"

  , testCase "an explicit deadline bounds an accepted waiting hook" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        snapshot <- Tmux.capture server
        window <- one (Tmux.windows snapshot)
        configured fixture ["set-hook", "-g", "after-rename-window",
          "wait-for -S libtmux-deadline-entered ; wait-for libtmux-deadline-release"]
        let release = do
              configured fixture ["wait-for", "-S", "libtmux-deadline-release"]
              configured fixture ["set-hook", "-gu", "after-rename-window"]
            options = Tmux.defaultMutationOptions {Tmux.timeout = 0.2}
        flip finally release $
          withAsync (configured fixture ["wait-for", "libtmux-deadline-entered"]) $ \entered ->
            withAsync (Tmux.tryTmux (Tmux.renameWindowWith options server window.ref "deadline-applied")) $ \worker -> do
              bounded (wait entered)
              timeout 500000 (wait worker) >>= \case
                Just (Left (ExceptionWithContext context Tmux.MutationTimedOut)) ->
                  case Tmux.mutationRecoveries context of
                    [recovery] -> do
                      observed <- bounded (Tmux.awaitMutationRecovery recovery)
                      observed.logical.outcome @?= Just Tmux.OutcomeUnknown
                      observed.logical.retained @?= True
                      release
                      Tmux.detachMutationRecovery recovery >>= (@?= True)
                    _ -> assertFailure "deadline lost its accepted operation"
                _ -> assertFailure "explicit timeout did not bound the call"

  , testCase "accepted cancellation exposes recovery and permits explicit later progress" $
      Fixture.withFixture $ \fixture ->
        Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime (config fixture) $ \server -> do
          snapshot <- Tmux.capture server
          window <- one (Tmux.windows snapshot)
          configured fixture ["set-hook", "-g", "after-rename-window",
            "wait-for -S libtmux-public-entered ; wait-for libtmux-public-release"]
          let release = do
                configured fixture ["wait-for", "-S", "libtmux-public-release"]
                configured fixture ["set-hook", "-gu", "after-rename-window"]
          flip finally release $
            withAsync (configured fixture ["wait-for", "libtmux-public-entered"]) $ \entered ->
              withAsync (tryWithContext @SomeException (Tmux.renameWindow server window.ref "accepted")) $ \worker -> do
                bounded (wait entered)
                throwTo (asyncThreadId worker) ThreadKilled
                bounded (wait worker) >>= \case
                  Left (ExceptionWithContext context problem) -> do
                    fromException @AsyncException problem @?= Just ThreadKilled
                    case Tmux.mutationRecoveries context of
                      [recovery] -> do
                        Tmux.mutationGeneration recovery @?= Tmux.serverGeneration server
                        observed <- bounded (Tmux.awaitMutationRecovery recovery)
                        observed.workerOwned @?= False
                        observed.nativeOwned @?= False
                        observed.logical.outcome @?= Just Tmux.OutcomeUnknown
                        observed.logical.retained @?= True
                        Tmux.resumeMutationRecovery recovery
                        release
                        Tmux.detachMutationRecovery recovery >>= (@?= True)
                        Tmux.renameWindow server window.ref "after-public-recovery"
                        after <- Tmux.capture server
                        changed <- require (Tmux.lookupWindow after window.ref)
                        changed.name @?= "after-public-recovery"
                      _ -> assertFailure "cancelled public call lost its owner"
                  Right () -> assertFailure "cancelled public mutation returned success"
  ]

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}

configured :: Fixture.Fixture -> [String] -> Assertion
configured fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, output, errors) @?= (ExitSuccess, "", "")

one :: [a] -> IO a
one [value] = pure value
one _ = fail "owned fixture has an unexpected entity count"

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure

expectInvalidTarget :: Either (ExceptionWithContext Tmux.TmuxException) () -> Assertion
expectInvalidTarget (Left (ExceptionWithContext _ (Tmux.InvalidTarget _))) = pure ()
expectInvalidTarget _ = assertFailure "foreign target admitted a mutation"

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "public mutation missed its event") pure
