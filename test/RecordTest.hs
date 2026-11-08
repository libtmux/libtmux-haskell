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
  , testCase "requires metadata and a complete attached-client section" $ withNonce $ \nonce -> do
      snapshot <- require (R.decodeSnapshot generation nonce
        (snapshotWire (session <> window "editor" <> link "$1" "1" "1" <> pane) (client "22" <> client "11")))
      (G.serverInfo snapshot).pid @?= 100
      map (.pid) (G.clients snapshot) @?= [11, 22]
      map (.name) (G.clients snapshot) @?= replicate 2 (Os.fromBytestring "tty\255")
      map (.tty) (G.clients snapshot) @?= [Nothing, Nothing]
      mapM_ (\bytes -> assertBool "incomplete Snapshot admitted" (isLeft (R.decodeSnapshot generation nonce bytes)))
        [valid, snapshotWire "" (client "1"), snapshotWire "" "" <> "hook\n",
         marker <> ":O:1\n" <> server <> marker <> ":Z\n",
         snapshotWire "" (row "C" []), snapshotWire "" (client "0")]
  , testCase "accepts explicit zero sessions and validates server metadata" $ withNonce $ \nonce -> do
      empty <- require (R.decodeSnapshot generation nonce (snapshotWire "" ""))
      G.graphSessions (G.entities empty) @?= []
      G.clients empty @?= []
      let invalidPid = marker <> ":O:1\n" <> row "I"
            [("server.pid", "0"), ("server.startedAt", "0"), ("server.version", "3.3a"), ("server.socketPath", "/tmp/s")]
            <> marker <> ":A\n" <> marker <> ":Z\n"
      R.decodeSnapshot generation nonce invalidPid
        @?= Left (R.InvalidRecordField (Field.FieldError "server.pid" Field.InvalidSyntax))
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

server :: ByteString
server = row "I" [("server.pid", "100"), ("server.startedAt", "1700000000"),
  ("server.version", "3.3a"), ("server.socketPath", "/tmp/s")]

client :: ByteString -> ByteString
client pid = row "C" [("client.name", "tty\\377"), ("client.pid", pid), ("client.tty", ""),
  ("client.session", "$1"), ("client.window", "@7"), ("client.windowIndex", "1"), ("client.pane", "%9")]

snapshotWire :: ByteString -> ByteString -> ByteString
snapshotWire physical attached = marker <> ":O:1\n" <> server <> physical <> marker <> ":A\n"
  <> attached <> marker <> ":Z\n"

withNonce :: (Frame.Nonce -> IO ()) -> IO ()
withNonce action = require (Frame.parseNonce token) >>= action

require :: Show error => Either error value -> IO value
require = either (fail . show) pure
