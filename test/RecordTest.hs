module RecordTest (tests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Either (isLeft)
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Frame qualified as Frame
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Record qualified as R
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as Value
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck qualified as Q

tests :: TestTree
tests = testGroup "tagged graph records"
  [ testCase "validates contextual repetition and retains typed owned fields" $ withNonce $ \nonce -> do
      graph <- require (R.decodeGraph generation nonce
        (wire (session <> window "lo\\147s" <> link "$1" "1" "1" <> pane
          <> window "lo\\147s" <> link "$1" "4" "0" <> pane)))
      length (G.graphOccurrences graph) @?= 2
      map (.attached) (G.graphSessions graph) @?= [0]
      map (Label.toBytes . (.name)) (G.graphWindows graph) @?= ["logs"]
      case G.graphPanes graph of
        [observed] -> do
          Value.dimensionValue observed.width @?= 120
          Value.dimensionValue observed.height @?= 40
          observed.title @?= "editor\nline"
          observed.currentCommand @?= Os.fromBytestring "cmd\255"
          observed.currentPath @?= Os.fromBytestring "/tmp/g"
        _ -> fail "one physical pane required"
  , testCase "accepts explicit emptiness and rejects structural changes and trailing output" $ withNonce $ \nonce -> do
      empty <- require (R.decodeGraph generation nonce (wire ""))
      G.graphSessions empty @?= []
      graph <- require (R.decodeGraph generation nonce (wire (session <> window "" <> link "$1" "1" "1" <> pane)))
      map (Label.toBytes . (.name)) (G.graphWindows graph) @?= [""]
      mapM_ (\bytes -> assertBool "malformed record admitted" (isLeft (R.decodeGraph generation nonce bytes)))
        ["hook\n" <> valid, valid <> "hook\n", Bytes.init valid,
         wire (row "Q" []), wire (session <> window "x" <> pane),
         wire (row "S" [("session.name", "work"), ("session.id", "$1"), ("session.attached", "0")])]
      R.decodeGraph generation nonce (wire (window "x")) @?= Left R.InvalidRecordContext
      R.decodeGraph generation nonce (wire (session <> window "x" <> link "$2" "1" "1" <> pane))
        @?= Left R.InvalidRecordContext
  , testCase "rejects encoding drift, decoded nonce collisions and invalid numeric fields" $ withNonce $ \nonce -> do
      let named name = wire (session <> window name <> link "$1" "1" "1" <> pane)
      R.decodeGraph generation nonce (named "logs") @?= Left (R.InvalidRecordScalar Frame.ReservedRecordByte)
      R.decodeGraph generation nonce (named (Bytes.concat (replicate 64 "\\141")))
        @?= Left (R.InvalidRecordScalar Frame.AmbiguousScalarFrame)
      R.decodeGraph generation nonce (named "\\x") @?= Left (R.InvalidRecordScalar (Frame.InvalidScalarEscape 0))
      R.decodeGraph generation nonce (named "\NUL") @?= Left (R.InvalidRecordScalar Frame.NulInScalar)
      R.decodeGraph generation nonce (wire (row "S" [("session.id", "$1"), ("session.name", "work"), ("session.attached", "-1")]))
        @?= Left (R.InvalidRecordField (Field.FieldError "session.attached" Field.InvalidSyntax))
      R.decodeGraph generation nonce (Bytes.replicate 1048577 120) @?= Left (R.RecordWireLimit 1048577)
      assertBool "conflicting repeated physical name admitted" (isLeft (R.decodeGraph generation nonce
        (wire (session <> window "one" <> link "$1" "1" "1" <> pane
          <> window "two" <> link "$1" "4" "0" <> pane))))
  , Q.testProperty "round trips generated field bytes without confusing record delimiters" $
      Q.forAllShrink (Q.resize 128 (Q.listOf (Q.chooseEnum (1, 255)))) (Q.shrinkList (const [])) $ \values ->
        let original = Bytes.pack values
            escaped = Bytes.concatMap (\byte -> case byte of
              92 -> "\\\\"
              103 -> "\\147"
              _ -> Bytes.singleton byte) original
        in not (token `Bytes.isInfixOf` original) Q.==>
          case Frame.parseNonce token of
            Left problem -> Q.counterexample (show problem) False
            Right nonce -> fmap (map (Label.toBytes . (.name)) . G.graphWindows)
              (R.decodeGraph generation nonce (wire (session <> window escaped <> link "$1" "1" "1" <> pane)))
                Q.=== Right [original]
  ]

generation :: G.Generation
generation = G.Generation (G.EndpointIdentity 7 11) (Bytes.replicate 32 1)

token, marker, valid, session, pane :: ByteString
token = Bytes.replicate 64 97
marker = "g" <> token
valid = wire (session <> window "lo\\147s" <> link "$1" "1" "1" <> pane)
session = row "S" [("session.id", "$1"), ("session.name", "work"), ("session.attached", "0")]
pane = row "P" [("pane.id", "%9"), ("pane.window", "@7"), ("pane.index", "0"),
  ("pane.width", "120"), ("pane.height", "40"), ("pane.active", "1"), ("pane.dead", "0"),
  ("pane.title", "editor\\nline"), ("pane.currentCommand", "cmd\\377"), ("pane.currentPath", "/tmp/\\147")]

window :: ByteString -> ByteString
window name = row "W" [("window.id", "@7"), ("window.name", name), ("window.width", "120"), ("window.height", "40")]

link :: ByteString -> ByteString -> ByteString -> ByteString
link owner index active = row "L" [("windowLink.session", owner), ("windowLink.window", "@7"),
  ("windowLink.index", index), ("windowLink.active", active)]

row :: ByteString -> [(ByteString, ByteString)] -> ByteString
row tag fields = marker <> ":" <> tag <> "\n"
  <> foldMap (\(key, value) -> marker <> ":F:" <> key <> ":" <> value <> ":" <> marker <> "\n") fields
  <> marker <> ":E\n"

wire :: ByteString -> ByteString
wire body = marker <> ":G:1\n" <> body <> marker <> ":Z\n"

withNonce :: (Frame.Nonce -> IO ()) -> IO ()
withNonce action = require (Frame.parseNonce token) >>= action

require :: Show error => Either error value -> IO value
require = either (fail . show) pure
