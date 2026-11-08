module BudgetTest (tests) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (try)
import Control.Monad (replicateM)
import LibTmux.Internal.Budget qualified as B
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "shared resource budget"
  [ testCase "a context admits eight clients and no ninth" $ do
      budget <- B.newBudget 100
      leases <- atomically (replicateM 8 (B.acquireClient budget))
      exhausted (B.Exhausted B.Clients 1 8 8) (B.acquireClient budget)
      atomically (mapM_ B.releaseClient leases)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
  , testCase "a context admits sixteen child reservations and no seventeenth" $ do
      budget <- B.newBudget 100
      leases <- atomically (replicateM 16 (B.acquireChild budget B.Inspection 0))
      exhausted (B.Exhausted B.Children 1 16 16) (B.acquireChild budget B.Inspection 0)
      atomically (mapM_ B.releaseChild leases)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
  , testCase "byte exhaustion cannot partially reserve a child" $ do
      budget <- B.newBudget 100
      held <- atomically (B.acquireBytes budget B.Inspection (128 * 1024 * 1024 - 100))
      exhausted (B.Exhausted B.PendingBytes 101 (128 * 1024 * 1024 - 100) (128 * 1024 * 1024))
        (B.acquireChild budget B.Inspection 101)
      state <- atomically (B.usage budget)
      state.children @?= 0
      atomically (B.releaseBytes held)
      child <- atomically (B.acquireChild budget B.Inspection 100)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 1 100)
      atomically (B.releaseChild child)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
  , testCase "exact byte capacity works and oversized additions cannot wrap" $ do
      budget <- B.newBudget 100
      full <- atomically (B.acquireBytes budget B.Inspection (128 * 1024 * 1024))
      exhausted (B.Exhausted B.PendingBytes 1 (128 * 1024 * 1024) (128 * 1024 * 1024))
        (B.acquireBytes budget B.Inspection 1)
      atomically (B.releaseBytes full)
      one <- atomically (B.acquireBytes budget B.Inspection 1)
      exhausted (B.Exhausted B.PendingBytes maxBound 1 (128 * 1024 * 1024))
        (B.acquireBytes budget B.Inspection maxBound)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 1)
      atomically (B.releaseBytes one)
  , testCase "closed admission preserves leases and repeated release is harmless" $ do
      budget <- B.newBudget 100
      client <- atomically (B.acquireClient budget)
      child <- atomically (B.acquireChild budget B.Ordinary 5)
      bytes <- atomically (B.acquireBytes budget B.Inspection 7)
      atomically (B.closeAdmission budget)
      atomically (B.usage budget) >>= (@?= B.Usage False 1 1 12)
      exhausted B.AdmissionClosed (B.acquireClient budget)
      exhausted B.AdmissionClosed (B.acquireChild budget B.Inspection 0)
      exhausted B.AdmissionClosed (B.acquireBytes budget B.Inspection 0)
      atomically $ do
        B.releaseClient client
        B.releaseChild child
        B.releaseBytes bytes
        B.releaseClient client
        B.releaseChild child
        B.releaseBytes bytes
      atomically (B.usage budget) >>= (@?= B.Usage False 0 0 0)
  , testCase "ordinary children cannot consume the inspection position" $ do
      budget <- B.newBudget 100
      ordinary <- atomically (replicateM 15 (B.acquireChild budget B.Ordinary 0))
      exhausted (B.Exhausted B.OrdinaryChildren 1 15 15)
        (B.acquireChild budget B.Ordinary 0)
      inspection <- atomically (B.acquireChild budget B.Inspection 0)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 16 0)
      exhausted (B.Exhausted B.Children 1 16 16)
        (B.acquireChild budget B.Inspection 0)
      atomically (B.releaseChild inspection >> B.releaseChild inspection)
      exhausted (B.Exhausted B.OrdinaryChildren 1 15 15)
        (B.acquireChild budget B.Ordinary 0)
      atomically (mapM_ B.releaseChild ordinary)
      replacement <- atomically (B.acquireChild budget B.Ordinary 0)
      atomically (B.releaseChild replacement)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
  , testCase "ordinary payloads leave protected bytes after inspection retirement" $ do
      budget <- B.newBudget 100
      ordinary <- atomically (B.acquireBytes budget B.Ordinary 134217628)
      exhausted (B.Exhausted B.OrdinaryPendingBytes 1 134217628 134217628)
        (B.acquireBytes budget B.Ordinary 1)
      exhausted (B.Exhausted B.OrdinaryPendingBytes maxBound 134217628 134217628)
        (B.acquireBytes budget B.Ordinary maxBound)
      inspection <- atomically (B.acquireBytes budget B.Inspection 100)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 134217728)
      atomically (B.releaseBytes inspection >> B.releaseBytes inspection)
      exhausted (B.Exhausted B.OrdinaryPendingBytes 1 134217628 134217628)
        (B.acquireBytes budget B.Ordinary 1)
      atomically (B.releaseBytes ordinary >> B.releaseBytes ordinary)
      replacement <- atomically (B.acquireBytes budget B.Ordinary 134217628)
      atomically (B.releaseBytes replacement)
      atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
  , testCase "an oversized inspection reserve cannot wrap ordinary capacity" $
      try @B.LimitError (B.newBudget maxBound) >>= \case
        Left actual -> actual @?= B.Exhausted B.PendingBytes maxBound 0 134217728
        Right _ -> assertFailure "accepted an inspection reserve larger than the total byte limit"
  ]

exhausted :: B.LimitError -> STM a -> IO ()
exhausted expected action = try @B.LimitError (atomically action) >>= \case
  Left actual -> actual @?= expected
  Right _ -> assertFailure ("admitted work despite " <> show expected)
