module FieldTest (tests) where

import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Either (isLeft)
import LibTmux.Id qualified as Id
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as V
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck qualified as Q

tests :: TestTree
tests = testGroup "typed observation fields"
  [ testCase "checks numeric domains without accepting absence or narrowing" $ do
      mapM_ (rejected F.PaneWidth) ["", "0", "-1", "1.0", "4294967296", " 1", "1\n"]
      mapM_ (rejected F.LinkIndex) ["", "-1", "2147483648"]
      mapM_ (rejected F.PaneIndex) ["", "-1", "4294967296"]
      mapM_ (rejected F.SessionAttached) ["", "-1", "4294967296"]
      mapM_ (rejected F.PaneActive) ["", "true", "2", "00"]
      F.decodeField F.PaneActive "0" @?= Right False
      F.decodeField F.LinkActive "1" @?= Right True
      rejected F.SessionId "@1"
      rejected F.WindowId "%1"
      rejected F.PaneId "$1"
  , testCase "preserves non-text bytes and rejects invalid declared text" $ do
      let bytes = Bytes.pack [120, 255, 92, 51, 55, 55]
      fmap Label.toBytes (F.decodeField F.WindowName bytes) @?= Right bytes
      F.decodeField F.PaneCommand bytes @?= Right (Os.fromBytestring bytes)
      F.decodeField F.PanePath bytes @?= Right (Os.fromBytestring bytes)
      rejected F.SessionName bytes
      rejected F.PaneTitle bytes
      rejected F.PaneCommand "x\NULy"
      rejected F.WindowName "x\NULy"
      rejected F.PaneTitle (Bytes.replicate 1048577 120)
  , testCase "projects contextual IDs from the link and physical IDs from the row" $ do
      let generation = G.Generation (G.EndpointIdentity 7 11) (Bytes.replicate 32 1)
      sessionId <- require (Id.parseSessionId "$4")
      windowId <- require (Id.parseWindowId "@7")
      paneId <- require (Id.parsePaneId "%9")
      index <- require (V.mkWindowIndex 3)
      paneIndex <- require (V.mkPaneIndex 1)
      width <- require (V.mkDimension 120)
      height <- require (V.mkDimension 40)
      let sessionRef = G.SessionRef generation sessionId
          windowRef = G.WindowRef generation windowId
          session = G.Session sessionRef "work" 2
          window = G.Window windowRef "editor" width height
          pane = G.Pane (G.PaneRef generation paneId) windowRef paneIndex
            width height True False "title" (Os.fromBytestring "nvim") (Os.fromBytestring "/work")
          link = G.WindowLink sessionRef index windowRef False
      F.project F.SessionId session @?= sessionId
      F.project F.WindowId window @?= windowId
      F.project F.PaneId pane @?= paneId
      F.project F.PaneWindow pane @?= windowId
      F.project F.LinkSession link @?= sessionId
      F.project F.LinkWindow link @?= windowId
      F.project F.LinkIndex link @?= index
      F.project F.LinkActive link @?= False
      F.project F.PaneActive pane @?= True
      F.project F.PanePath pane @?= Os.fromBytestring "/work"
  , Q.testProperty "decodes every valid wire dimension as its mathematical value" $
      Q.forAll (Q.chooseInteger (1, 4294967295)) $ \value ->
        fmap V.dimensionValue (F.decodeField F.PaneWidth (Ascii.pack (show value))) Q.=== Right value
  ]

rejected :: Show a => F.Field row a -> Bytes.ByteString -> IO ()
rejected field bytes = assertBool "invalid field value admitted" (isLeft (F.decodeField field bytes))

require :: Show e => Either e a -> IO a
require = either (fail . show) pure
