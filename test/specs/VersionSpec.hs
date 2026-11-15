module VersionSpec (spec) where

import Control.Monad (forM_)
import Data.Char (ord)
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux.Version
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "tmux version admission" $ do
  it "admits the complete tested range including intermediate releases" $
    mapM_ (\raw -> fmap renderVersion (parseVersion raw >>= requireSupported) `shouldBe` Right raw)
      ["3.3a", "3.4", "3.5", "3.5a", "3.6", "3.6a", "3.6b", "3.7", "3.7a", "3.7b", "3.7c", "3.8"]
  it "admits newer numeric releases and patch letters without an upper bound" $
    forM_ ["3.8a", "3.8b", "3.9", "3.9a", "3.10", "4.0", "10.0", "10.12z"] $ \raw ->
      fmap renderVersion (parseVersion raw >>= requireSupported) `shouldBe` Right raw
  it "admits development builds and candidates ranked above the floor" $
    forM_ ["next-3.4", "3.4-rc", "3.4-rc2", "next-3.9", "3.9-rc", "3.9-rc1", "3.9-rc3", "next-4.0"] $ \raw ->
      fmap renderVersion (parseVersion raw >>= requireSupported) `shouldBe` Right raw
  it "parses tmux output without admitting a second line" $ do
    fmap renderVersion (parseVersion "tmux 3.3a\n") `shouldBe` Right "3.3a"
    fmap renderVersion (parseVersion "tmux next-3.9\n") `shouldBe` Right "next-3.9"
    fmap renderVersion (parseVersion "tmux 3.8-rc3\n") `shouldBe` Right "3.8-rc3"
    parseVersion "tmux 3.3\n3.8" `shouldSatisfy` isLeft
  it "orders development builds, candidates, releases and patch letters" $ do
    versions <- traverse release ascending
    forM_ (zip3 ascending versions [1 :: Int ..]) $ \(earlier, low, position) ->
      forM_ (drop position (zip ascending versions)) $ \(later, high) ->
        (earlier, later, compare low high) `shouldBe` (earlier, later, LT)
  it "orders numeric components numerically" $ do
    versions <- traverse release ["3.3a", "3.9", "3.10", "3.100", "4.0", "9.9", "9.10", "10.0"]
    and (zipWith (<) versions (drop 1 versions)) `shouldBe` True
    versions' <- traverse release ["3.9-rc2", "3.9-rc10", "3.9-rc11"]
    and (zipWith (<) versions' (drop 1 versions')) `shouldBe` True
  it "rejects releases below 3.3a including plain 3.3 and its predecessors" $
    forM_ ["1.9", "2.9a", "3.0", "3.2a", "3.3", "3.3-rc", "3.3-rc2", "next-3.3", "next-3.2", "2.9-rc"] $ \raw -> do
      version <- release raw
      requireSupported version `shouldBe` Left (UnsupportedVersion version)
  it "reproduces every accepted native token spelling" $
    forM_ ["next-3.9", "3.8-rc", "3.8-rc1", "3.8-rc2", "3.8-rc3", "3.8", "3.8a", "3.10", "10.0"] $ \raw ->
      fmap renderVersion (parseVersion raw) `shouldBe` Right raw
  it "does not guess a release for bare master or unknown suffixes" $
    forM_ ["master", "main", "next", "3.8-dev", "3.8-master", "3.8-beta", "3.8-rc1-1", "3.8-", "openbsd-7.4"] $ \raw ->
      parseVersion raw `shouldBe` Left (MalformedVersion raw)
  it "rejects malformed version claims" $
    forM_ [ "", "3.8a-next", "3.3aa", "3.3A", "3", "3.3.0", "03.3", "3.-3", "3.3 ", "tmux 3.3\n\n", "3.３"
          , "tmux  3.8", "tmux master", "tmux next-3.9\n\n", "3.8\r\n"
          , "next-", "next-3", "next-3.", "next-3.8a", "next-3.8-rc", "next-3.8-rc1", "next-next-3.9"
          , "Next-3.9", "next3.9", "next--3.9", "next-03.9", "next-3.09"
          , "3.8a-rc", "3.8a-rc1", "3.8-rc0", "3.8-rc01", "3.8-rc1a", "3.8-rc-1", "3.8-RC1", "3.8rc1"
          , "3.8-rc ", "3.8-rc1 ", "3.8-rc1\n\n", "3.8 -rc1", "3.8-rc1.0"
          ] $ \raw ->
      parseVersion raw `shouldSatisfy` isLeft
  it "bounds the diagnostic copy of malformed input" $ do
    forM_ [Text.replicate 200 "x", "3." <> Text.replicate 80 "9", "next-" <> Text.replicate 80 "3"] $ \raw ->
      case parseVersion raw of
        Left (MalformedVersion copy) -> copy `shouldBe` Text.take 64 raw
        other -> expectationFailure ("expected a bounded malformed diagnostic, got " <> show other)
  it "orders generated spellings by numbers then stage and reproduces them" $
    property $ forAll ((,) <$> spelling <*> spelling) $ \(left, right) ->
      let parsed = (,) <$> parseVersion (token left) <*> parseVersion (token right)
      in counterexample (show (token left, token right)) $
           fmap (uncurry compare) parsed === Right (compare (rank left) (rank right))
             .&&. fmap (renderVersion . fst) parsed === Right (token left)

-- | Every earlier spelling ranks below every later one.
ascending :: [Text]
ascending =
  [ "next-3.3", "3.3-rc", "3.3-rc1", "3.3-rc2", "3.3-rc10", "3.3", "3.3a", "3.3b", "3.3z"
  , "next-3.4", "3.4-rc", "3.4-rc2", "3.4", "3.4a"
  , "next-3.9", "3.9-rc", "3.9-rc1", "3.9-rc3", "3.9", "3.9a", "3.9b"
  , "next-3.10", "3.10-rc2", "3.10", "3.10a", "4.0", "9.9", "next-10.0", "10.0-rc", "10.0"
  ]

release :: Text -> IO TmuxVersion
release raw = either (\problem -> fail ("valid release failed parsing: " <> show raw <> ": " <> show problem)) pure (parseVersion raw)

data Stage = Development | BareCandidate | Candidate Integer | Final | Patch Char
  deriving stock Show

data Spelling = Spelling Integer Integer Stage
  deriving stock Show

spelling :: Gen Spelling
spelling = Spelling <$> chooseInteger (0, 12) <*> frequency [(3, chooseInteger (0, 12)), (2, chooseInteger (0, 120))] <*> stage
  where
    stage = frequency
      [ (1, pure Development), (1, pure BareCandidate)
      , (2, Candidate <$> chooseInteger (1, 30)), (2, pure Final)
      , (2, Patch <$> elements ['a' .. 'z']) ]

token :: Spelling -> Text
token (Spelling major minor stage) = case stage of
  Development -> "next-" <> numbers
  BareCandidate -> numbers <> "-rc"
  Candidate number -> numbers <> "-rc" <> Text.pack (show number)
  Final -> numbers
  Patch letter -> numbers <> Text.singleton letter
  where numbers = Text.pack (show major <> "." <> show minor)

-- | Numeric components first, then development < bare candidate < numbered
-- candidates < release < patch letters.
rank :: Spelling -> (Integer, Integer, Int, Integer)
rank (Spelling major minor stage) = (major, minor, kind, extra)
  where
    (kind, extra) = case stage of
      Development -> (0, 0)
      BareCandidate -> (1, 0)
      Candidate number -> (1, number)
      Final -> (2, 0)
      Patch letter -> (3, toInteger (ord letter))
