module GraphTest (tests) where

import Data.ByteString qualified as Bytes
import Data.Either (isLeft)
import LibTmux.Id
import LibTmux.Internal.Graph
import LibTmux.Internal.Graph qualified as Info (ServerInfo (..))
import LibTmux.Internal.Graph qualified as Input (ClientInput (..))
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value
import LibTmux.Version qualified as Version
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "detached entity graph"
  [ testCase "preserves repeated links and occurrence order while normalizing physical rows" $
      fixture $ \generation session window pane first second -> do
        graph <- require (assembleEntityGraph generation [session] [window, window] [pane, pane] [second, first])
        graphWindows graph @?= [window]
        graphPanes graph @?= [pane]
        graphLinks graph @?= [first, second]
        graphOccurrences graph @?= [PaneOccurrence pane first, PaneOccurrence pane second]
        linksForSession graph session.ref @?= Right [first, second]
        panesForWindow graph window.ref @?= Right [pane]
  , testCase "rejects conflicting observations of the same physical object" $
      fixture $ \generation session window pane first _ -> do
        let changed = Window window.ref "changed" window.width window.height
        assembleEntityGraph generation [session] [window, changed] [pane] [first]
          @?= Left (ConflictingWindow window.ref)
        assembleEntityGraph generation [session] [window] [pane, pane {title = "changed"}] [first]
          @?= Left (ConflictingPane pane.ref)
  , testCase "rejects dangling edges and duplicate contextual slots" $
      fixture $ \generation session window pane first _ -> do
        assembleEntityGraph generation [] [window] [pane] [first] @?= Left (MissingSession session.ref)
        assembleEntityGraph generation [session] [] [pane] [first] @?= Left (MissingWindow window.ref)
        assembleEntityGraph generation [session] [window] [pane] [first, first]
          @?= Left (DuplicateWindowSlot session.ref first.index)
  , testCase "rejects foreign generations at acquisition and lookup" $
      fixture $ \generation session window pane first _ -> do
        let foreignGeneration = Generation (EndpointIdentity 7 11) (Bytes.replicate 32 2)
        assertBool "foreign rows admitted" (isLeft (assembleEntityGraph foreignGeneration [session] [window] [pane] [first]))
        graph <- require (assembleEntityGraph generation [session] [window] [pane] [first])
        missing <- WindowRef generation <$> require (parseWindowId "@99")
        foreignRef <- WindowRef foreignGeneration <$> require (parseWindowId "@1")
        panesForWindow graph missing @?= Left (MissingWindow missing)
        panesForWindow graph foreignRef @?= Left ForeignGeneration
  , testCase "validates selected links, active panes and pane indices" $
      fixture $ \generation session window pane first second -> do
        let selected = WindowLink second.session second.index second.window True
            inactive = Pane pane.ref pane.window pane.index pane.width pane.height False
              pane.dead pane.title pane.currentCommand pane.currentPath
        assembleEntityGraph generation [session] [window] [pane] [first, selected]
          @?= Left (InvalidSessionSelection session.ref 2)
        assembleEntityGraph generation [session] [window] [inactive] [first]
          @?= Left (InvalidPaneSelection window.ref 0)
        anotherRef <- PaneRef generation <$> require (parsePaneId "%2")
        assembleEntityGraph generation [session] [window] [pane, pane {ref = anotherRef, active = False}] [first]
          @?= Left (DuplicatePaneIndex window.ref pane.index)
  , testCase "accepts an empty server graph and keeps identity separate from contents" $
      fixture $ \generation session window _ _ _ -> do
        empty <- require (assembleEntityGraph generation [] [] [] [])
        graphOccurrences empty @?= []
        graphSessions empty @?= []
        let renamed :: Window
            renamed = Window window.ref "renamed" window.width window.height
        assertBool "renamed observation compares equal" (window /= renamed)
        renamed.ref @?= window.ref
        assembleEntityGraph generation [session {attached = -1}] [] [] []
          @?= Left (InvalidAttachedCount session.ref (-1))
  , testCase "keeps label bytes when explicit UTF-8 conversion fails" $ do
      let bytes = Bytes.pack [120, 255, 121]
          label = Label.fromBytes bytes
      Label.toBytes label @?= bytes
      assertBool "invalid text was silently replaced" (isLeft (Label.decodeUtf8 label))
      Label.decodeUtf8 "editor λ" @?= Right "editor λ"
      Label.toBytes "λ" @?= Bytes.pack [206, 187]
  , testCase "retains detached attachments and duplicate client names without deriving counts" $
      fixture $ \generation session window pane first _ -> do
        graph <- require (assembleEntityGraph generation [session {attached = 0}] [window] [pane] [first])
        version <- require (Version.parseVersion "3.3a")
        let info = ServerInfo generation 100 1700000000 version (Os.fromBytestring "/tmp/socket")
            SessionRef _ sessionId = session.ref
            WindowRef _ windowId = window.ref
            PaneRef _ paneId = pane.ref
            named = Os.fromBytestring "same\255"
            client = ClientInput named 2 Nothing sessionId windowId first.index paneId
        snapshot <- require (assembleSnapshot info graph [client, client {Input.pid = 1}])
        map (.pid) (clients snapshot) @?= [1, 2]
        map (.name) (clients snapshot) @?= [named, named]
        map (.attachment) (clients snapshot) @?= replicate 2
          (Just (ClientAttachment (session {attached = 0}) window (PaneOccurrence pane first)))
        repeated <- require (assembleSnapshot info graph [client, client])
        length (clients repeated) @?= 2
        let offline = Client named 1 Nothing Nothing
        offline.attachment @?= Nothing
        Field.project Field.ClientName offline @?= named
  , testCase "rejects foreign metadata and missing or changed client attachment contexts" $
      fixture $ \generation session window pane first second -> do
        graph <- require (assembleEntityGraph generation [session] [window] [pane] [first, second])
        version <- require (Version.parseVersion "3.3a")
        let info = ServerInfo generation 100 0 version (Os.fromBytestring "/tmp/socket")
            SessionRef _ sessionId = session.ref
            WindowRef _ windowId = window.ref
            PaneRef _ paneId = pane.ref
            client = ClientInput (Os.fromBytestring "client") 2 Nothing sessionId windowId first.index paneId
            otherGeneration = Generation (EndpointIdentity 7 11) (Bytes.replicate 32 2)
        assembleSnapshot (info {Info.generation = otherGeneration}) graph [] @?= Left ForeignGeneration
        assembleSnapshot (info {Info.pid = 0}) graph [] @?= Left InvalidServerInfo
        assembleSnapshot info graph [client {Input.pid = 0}] @?= Left InvalidClientMetadata
        assembleSnapshot info graph [client {Input.index = second.index}] @?= Left ChangedClientAttachment
        missing <- require (mkWindowIndex 9)
        assembleSnapshot info graph [client {Input.index = missing}] @?= Left (MissingClientLink session.ref missing)
  ]

require :: Show e => Either e a -> IO a
require = either (fail . show) pure

fixture :: (Generation -> Session -> Window -> Pane -> WindowLink -> WindowLink -> IO ()) -> IO ()
fixture action = do
  let generation = Generation (EndpointIdentity 7 11) (Bytes.replicate 32 1)
  sessionRef <- SessionRef generation <$> require (parseSessionId "$1")
  windowRef <- WindowRef generation <$> require (parseWindowId "@1")
  paneRef <- PaneRef generation <$> require (parsePaneId "%1")
  width <- require (mkDimension 120)
  height <- require (mkDimension 40)
  firstIndex <- require (mkWindowIndex 1)
  secondIndex <- require (mkWindowIndex 4)
  paneIndex <- require (mkPaneIndex 0)
  let session = Session sessionRef "work" 2
      window = Window windowRef "editor" width height
      pane = Pane paneRef windowRef paneIndex width height True False "editor"
        (Os.fromBytestring "nvim") (Os.fromBytestring "/work")
      first = WindowLink sessionRef firstIndex windowRef True
      second = WindowLink sessionRef secondIndex windowRef False
  action generation session window pane first second
