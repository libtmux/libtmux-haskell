-- | Pure selection descriptions and cardinality over detached observations.
module LibTmux.Internal.Query
  ( CardinalityError (..), exactlyOne, atMostOne
  ) where

-- | Selection cardinality without retaining observations or counting ambiguity.
data CardinalityError
  = NoMatches
  | AtLeastTwoMatches
  deriving stock (Eq, Show)

exactlyOne :: [row] -> Either CardinalityError row
exactlyOne [] = Left NoMatches
exactlyOne [row] = Right row
exactlyOne (_ : _ : _) = Left AtLeastTwoMatches

atMostOne :: [row] -> Either CardinalityError (Maybe row)
atMostOne [] = Right Nothing
atMostOne [row] = Right (Just row)
atMostOne (_ : _ : _) = Left AtLeastTwoMatches
