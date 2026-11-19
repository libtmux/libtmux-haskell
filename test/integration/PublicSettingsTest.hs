module PublicSettingsTest (tests) where

import Control.Exception (ExceptionWithContext (..))
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Fixture qualified
import LibTmux qualified as Tmux
import System.Exit (ExitCode (..))
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public settings"
  [ testCase "keeps local, inherited, empty and literal values distinct" $
      withSettings $ \fixture server session window pane -> do
        let local = Tmux.SessionOptionsAt session
            candidate = Tmux.StringValue ("value #{pid}\n" <> Bytes.pack [255, 10] <> "end;")
            readLocal target name = Tmux.readOption server target Tmux.LocalOption name
        Tmux.setOption server Tmux.GlobalSessionOptions "status-left" (Tmux.StringValue "shared")
        expect Nothing (readLocal local "status-left")
        expect (Just (Tmux.StringValue "shared"))
          (Tmux.readOption server local Tmux.EffectiveOption "status-left")
        Tmux.setOption server local "status-left" (Tmux.StringValue "")
        expect (Just (Tmux.StringValue "")) (readLocal local "status-left")
        Tmux.unsetOption server local "status-left"
        expect Nothing (readLocal local "status-left")
        Tmux.setOption server local "@literal" candidate
        expect (Just candidate) (readLocal local "@literal")
        Tmux.setOption server Tmux.ServerOptions "buffer-limit" (Tmux.NumberValue 25)
        expect (Just (Tmux.NumberValue 25)) (readLocal Tmux.ServerOptions "buffer-limit")
        Tmux.setOption server (Tmux.WindowOptionsAt window) "remain-on-exit" (Tmux.ChoiceValue "off")
        Tmux.setOption server (Tmux.PaneOptionsAt pane) "remain-on-exit" (Tmux.ChoiceValue "on")
        expect (Just (Tmux.ChoiceValue "off")) (readLocal (Tmux.WindowOptionsAt window) "remain-on-exit")
        expect (Just (Tmux.ChoiceValue "on")) (readLocal (Tmux.PaneOptionsAt pane) "remain-on-exit")
        configured fixture ["set-hook", "-g", "after-show-options", "display-message -p unrelated-output"]
        expect (Just candidate) (readLocal local "@literal")

  , testCase "rejects wrong scope and kind before native option effects" $
      withSettings $ \_ server session window _ -> do
        let local = Tmux.SessionOptionsAt session
            physical = Tmux.WindowOptionsAt window
        Tmux.setOption server local "status-left" (Tmux.StringValue "before")
        Tmux.tryTmux (Tmux.setOption server physical "status-left" (Tmux.StringValue "wrong session"))
          >>= refused (Tmux.WrongSettingScope "status-left" Tmux.WindowScope)
        Tmux.tryTmux (Tmux.readOption server physical Tmux.LocalOption "status-left")
          >>= refused (Tmux.WrongSettingScope "status-left" Tmux.WindowScope)
        Tmux.tryTmux (Tmux.setOption server local "status-left" (Tmux.NumberValue 1))
          >>= refused (Tmux.WrongOptionKind "status-left" Tmux.StringKind)
        Tmux.tryTmux (Tmux.setOption server local "status-position" (Tmux.ChoiceValue "invalid"))
          >>= refused (Tmux.UnknownOptionChoice "status-position")
        Tmux.tryTmux (Tmux.readOption server local Tmux.LocalOption "status-format")
          >>= refused (Tmux.ExpectedScalarOption "status-format")
        expect (Just (Tmux.StringValue "before"))
          (Tmux.readOption server local Tmux.LocalOption "status-left")

  , testCase "reads ordered native hook entries and fires the selected event" $
      withSettings $ \_ server session window _ -> do
        let local = Tmux.SessionOptionsAt session
            event = "after-rename-window"
        Tmux.readHook server local event >>= (@?= Nothing)
        Tmux.setHook server local event 0 "set-option -g @hook-hit first"
        Tmux.setHook server local event 3 "set-option -g @hook-hit last"
        Tmux.readHook server local event >>= (@?= Just
          "after-rename-window[0] set-option -g @hook-hit first\nafter-rename-window[3] set-option -g @hook-hit last\n")
        Tmux.tryTmux (Tmux.setHook server Tmux.ServerOptions event 0 "display-message wrong")
          >>= refused (Tmux.WrongSettingScope event Tmux.ServerScope)
        Tmux.tryTmux (Tmux.readHook server (Tmux.WindowOptionsAt window) event)
          >>= refused (Tmux.WrongSettingScope event Tmux.WindowScope)
        Tmux.renameWindow server window "hook-target"
        expect (Just (Tmux.StringValue "last"))
          (Tmux.readOption server Tmux.GlobalSessionOptions Tmux.LocalOption "@hook-hit")
        Tmux.unsetHook server local event
        Tmux.readHook server local event >>= (@?= Nothing)

  , testCase "a missing local scope and a failed after-hook are distinct failures" $
      withSettings $ \fixture server _ _ _ -> do
        created <- Tmux.createSession server (Tmux.defaultSessionOptions {Tmux.name = Just "short-settings"})
        Tmux.killSession server created.session
        Tmux.tryTmux (Tmux.readOption server (Tmux.SessionOptionsAt created.session) Tmux.LocalOption "status-left")
          >>= \case
            Left (ExceptionWithContext _ (Tmux.SettingReadRejected _)) -> pure ()
            _ -> assertFailure "missing scope appeared to have an absent option"
        Tmux.setOption server Tmux.GlobalSessionOptions "@local" (Tmux.StringValue "value")
        configured fixture ["set-hook", "-g", "after-show-options", "run-shell -C missing-settings-command"]
        Tmux.tryTmux (Tmux.readOption server Tmux.GlobalSessionOptions Tmux.LocalOption "@local")
          >>= \case
            Left (ExceptionWithContext _ (Tmux.SettingReadHookFailed _)) -> pure ()
            _ -> assertFailure "failed after-hook appeared to be a successful read"
  ]

withSettings :: (Fixture.Fixture -> Tmux.Server -> Tmux.SessionRef -> Tmux.WindowRef -> Tmux.PaneRef -> Assertion)
  -> Assertion
withSettings action = Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
  snapshot <- Tmux.capture server
  case (Tmux.sessions snapshot, Tmux.windows snapshot, Tmux.panes snapshot) of
    ([session], [window], [pane]) -> action fixture server session.ref window.ref pane.ref
    _ -> assertFailure "expected one fixture session, window and pane"
  where
    config fixture = (Tmux.serverConfig (Os.fromBytestring (Ascii.pack fixture.socket)))
      {Tmux.executable = Os.fromBytestring (Ascii.pack fixture.executable)}

configured :: Fixture.Fixture -> [String] -> Assertion
configured fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, output, errors) @?= (ExitSuccess, "", "")

expect :: Maybe Tmux.OptionValue -> IO (Maybe Tmux.OptionValue) -> Assertion
expect expected action = action >>= assertBool "unexpected option value" . (== expected)

refused :: Tmux.OptionError -> Either (ExceptionWithContext Tmux.TmuxException) value -> Assertion
refused expected = \case
  Left (ExceptionWithContext context (Tmux.InvalidSetting actual)) -> do
    actual @?= expected
    assertBool "configuration refusal retained a mutation" (null (Tmux.mutationRecoveries context))
    assertBool "configuration refusal retained a read" (null (Tmux.captureRecoveries context))
  _ -> assertFailure "configuration was admitted"
