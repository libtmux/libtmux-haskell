{-# LANGUAGE RoleAnnotations #-}

-- | Closed typed selections over owned observations. Preparation and evaluation
-- are pure; acquisition belongs to the public Server boundary.
module LibTmux.Internal.Query
  ( CardinalityError (..), exactlyOne, atMostOne
  , Expr, Query, Order, ToMany (..), ToOne (..), ToOptional (..)
  , QueryError (..), QueryRequirements (..), EvaluatorProfile (..), nativeProfile
  , eq, oneOf, contains, ge, gt, le, lt
  , dimensionAtLeast, dimensionAtMost, paneIndexAtLeast, paneIndexAtMost
  , windowIndexAtLeast, windowIndexAtMost
  , allOf, anyOf, not_, some, every, none, related, optionalRelated
  , sessions, windows, panes, windowLinks, paneOccurrences, clients, serverInfo
  , matching, orderBy, ascending, descending, limit
  , requirements, prepare, runQuery, runQueryWith, evaluateExpr
  ) where

import Control.Monad (filterM, forM_, unless, when)
import Data.Bifunctor (first)
import Data.List (sortBy)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Graph qualified as G
import LibTmux.Value qualified as V
import LibTmux.Version qualified as Version
import Numeric.Natural (Natural)

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

data ToMany parent child where
  SessionLinks :: ToMany G.Session G.WindowLink
  SessionClients :: ToMany G.Session G.Client
  WindowPanes :: ToMany G.Window G.Pane
  WindowLinks :: ToMany G.Window G.WindowLink
  LinkPanes :: ToMany G.WindowLink G.Pane

data ToOne parent child where
  PaneWindow :: ToOne G.Pane G.Window
  LinkSession :: ToOne G.WindowLink G.Session
  LinkWindow :: ToOne G.WindowLink G.Window
  OccurrencePane :: ToOne G.PaneOccurrence G.Pane
  OccurrenceLink :: ToOne G.PaneOccurrence G.WindowLink
  AttachmentSession :: ToOne G.ClientAttachment G.Session
  AttachmentWindow :: ToOne G.ClientAttachment G.Window
  AttachmentPane :: ToOne G.ClientAttachment G.PaneOccurrence

data ToOptional parent child where
  ClientAttachment :: ToOptional G.Client G.ClientAttachment

data Source row where
  Sessions :: Source G.Session
  Windows :: Source G.Window
  Panes :: Source G.Pane
  WindowLinksSource :: Source G.WindowLink
  Occurrences :: Source G.PaneOccurrence
  Clients :: Source G.Client
  ServerInfo :: Source G.ServerInfo

data NumberField row where
  IntegerField :: F.Field row Integer -> NumberField row
  DimensionField :: F.Field row V.Dimension -> NumberField row
  PaneIndexField :: F.Field row V.PaneIndex -> NumberField row
  WindowIndexField :: F.Field row V.WindowIndex -> NumberField row

data Comparison = AtLeast | Above | AtMost | Below
data Quantifier = Some | Every | None

type role Expr nominal
data Expr row where
  Equal :: Eq value => F.Field row value -> value -> Expr row
  OneOf :: Eq value => F.Field row value -> [value] -> Expr row
  Contains :: F.Field row Text -> Text -> Expr row
  NumberCompare :: NumberField row -> Comparison -> Integer -> Expr row
  All :: [Expr row] -> Expr row
  Any :: [Expr row] -> Expr row
  Not :: Expr row -> Expr row
  Quantified :: Quantifier -> ToMany row child -> Expr child -> Expr row
  Related :: ToOne row child -> Expr child -> Expr row
  OptionalRelated :: ToOptional row child -> Expr child -> Expr row

type role Order nominal
data Order row where
  Order :: Ord value => Bool -> F.Field row value -> Order row

type role Query nominal
data Query row = Query !(Source row) !(Expr row) ![Order row] !(Maybe Natural)

data QueryError
  = FieldUnavailable !Text
  | RelationshipUnavailable !Text
  | RequiresTmux !Text !Version.TmuxVersion !Version.TmuxVersion
  | InvalidFieldRequirement !Text
  | RelationshipLookupFailed !Text !G.LookupError
  deriving stock (Eq, Show)

data QueryRequirements = QueryRequirements
  { sourceName :: !Text
  , fieldNames :: ![Text]
  , relationshipNames :: ![Text]
  , orderingFields :: ![Text]
  , rowLimit :: !(Maybe Natural)
  }
  deriving stock (Eq, Show)

data EvaluatorProfile = EvaluatorProfile
  { availableFields :: !(Set Text)
  , availableRelationships :: !(Set Text)
  , evaluatorVersion :: !(Maybe Version.TmuxVersion)
  }

eq :: Eq value => F.Field row value -> value -> Expr row
eq = Equal

oneOf :: Eq value => F.Field row value -> [value] -> Expr row
oneOf = OneOf

contains :: F.Field row Text -> Text -> Expr row
contains = Contains

ge, gt, le, lt :: F.Field row Integer -> Integer -> Expr row
ge field = NumberCompare (IntegerField field) AtLeast
gt field = NumberCompare (IntegerField field) Above
le field = NumberCompare (IntegerField field) AtMost
lt field = NumberCompare (IntegerField field) Below

dimensionAtLeast, dimensionAtMost :: F.Field row V.Dimension -> Integer -> Expr row
dimensionAtLeast field = NumberCompare (DimensionField field) AtLeast
dimensionAtMost field = NumberCompare (DimensionField field) AtMost

paneIndexAtLeast, paneIndexAtMost :: F.Field row V.PaneIndex -> Integer -> Expr row
paneIndexAtLeast field = NumberCompare (PaneIndexField field) AtLeast
paneIndexAtMost field = NumberCompare (PaneIndexField field) AtMost

windowIndexAtLeast, windowIndexAtMost :: F.Field row V.WindowIndex -> Integer -> Expr row
windowIndexAtLeast field = NumberCompare (WindowIndexField field) AtLeast
windowIndexAtMost field = NumberCompare (WindowIndexField field) AtMost

allOf, anyOf :: [Expr row] -> Expr row
allOf = All
anyOf = Any

not_ :: Expr row -> Expr row
not_ = Not

some, every, none :: ToMany row child -> Expr child -> Expr row
some = Quantified Some
every = Quantified Every
none = Quantified None

related :: ToOne row child -> Expr child -> Expr row
related = Related

optionalRelated :: ToOptional row child -> Expr child -> Expr row
optionalRelated = OptionalRelated

sessions :: Query G.Session
sessions = Query Sessions (All []) [] Nothing
windows :: Query G.Window
windows = Query Windows (All []) [] Nothing
panes :: Query G.Pane
panes = Query Panes (All []) [] Nothing
windowLinks :: Query G.WindowLink
windowLinks = Query WindowLinksSource (All []) [] Nothing
paneOccurrences :: Query G.PaneOccurrence
paneOccurrences = Query Occurrences (All []) [] Nothing
clients :: Query G.Client
clients = Query Clients (All []) [] Nothing
serverInfo :: Query G.ServerInfo
serverInfo = Query ServerInfo (All []) [] Nothing

matching :: Expr row -> Query row -> Query row
matching condition (Query source previous orders bound) =
  Query source (All [previous, condition]) orders bound

orderBy :: [Order row] -> Query row -> Query row
orderBy orders (Query source condition _ bound) = Query source condition orders bound

ascending, descending :: Ord value => F.Field row value -> Order row
ascending = Order False
descending = Order True

limit :: Natural -> Query row -> Query row
limit bound (Query source condition orders _) = Query source condition orders (Just bound)

nativeProfile :: EvaluatorProfile
nativeProfile = EvaluatorProfile
  (Set.fromList [F.fieldKey field | F.SomeField field <- F.catalogue])
  (Set.fromList
    [ fst (manyDescriptor SessionLinks), fst (manyDescriptor SessionClients)
    , fst (manyDescriptor WindowPanes), fst (manyDescriptor WindowLinks), fst (manyDescriptor LinkPanes)
    , fst (oneDescriptor PaneWindow), fst (oneDescriptor LinkSession), fst (oneDescriptor LinkWindow)
    , fst (oneDescriptor OccurrencePane), fst (oneDescriptor OccurrenceLink)
    , fst (oneDescriptor AttachmentSession), fst (oneDescriptor AttachmentWindow), fst (oneDescriptor AttachmentPane)
    , fst (optionalDescriptor ClientAttachment)
    ]) Nothing

requirements :: Query row -> QueryRequirements
requirements (Query source condition orders bound) =
  let (fields, relationships) = exprRequirements condition
      allFields = fields <> map orderField orders
  in QueryRequirements (sourceKey source)
       (Set.toAscList (Set.fromList (map someFieldKey allFields)))
       (Set.toAscList relationships) (map (someFieldKey . orderField) orders) bound

prepare :: EvaluatorProfile -> Query row -> Either QueryError ()
prepare profile (Query _ condition orders _) = do
  let (fields, relationships) = exprRequirements condition
      uniqueFields = Map.fromList [(someFieldKey field, field) | field <- fields <> map orderField orders]
  forM_ (Map.elems uniqueFields) $ \(F.SomeField field) -> do
    let key = F.fieldKey field
    unless (Set.member key profile.availableFields) (Left (FieldUnavailable key))
    minimumVersion <- first (const (InvalidFieldRequirement key)) (Version.parseVersion (F.minimumTmux field))
    forM_ profile.evaluatorVersion $ \actual ->
      when (actual < minimumVersion) (Left (RequiresTmux key minimumVersion actual))
  forM_ (Set.toAscList relationships) $ \key ->
    unless (Set.member key profile.availableRelationships) (Left (RelationshipUnavailable key))

runQuery :: G.Snapshot -> Query row -> Either QueryError [row]
runQuery snapshot = runQueryWith
  (nativeProfile {evaluatorVersion = Just (G.serverInfo snapshot).version}) snapshot

runQueryWith :: EvaluatorProfile -> G.Snapshot -> Query row -> Either QueryError [row]
runQueryWith profile snapshot query@(Query source condition orders bound) = do
  prepare profile query
  rows <- filterM (evaluateExpr snapshot condition) (sourceRows snapshot source)
  let ordered = if null orders then rows else sortBy (compareRows orders) rows
  pure (maybe ordered (`takeNatural` ordered) bound)

evaluateExpr :: G.Snapshot -> Expr row -> row -> Either QueryError Bool
evaluateExpr snapshot expression row = case expression of
  Equal field value -> Right (F.project field row == value)
  OneOf field values -> Right (F.project field row `elem` values)
  Contains field value -> Right (value `Text.isInfixOf` F.project field row)
  NumberCompare field comparison value -> Right (compareNumber comparison (numberValue field row) value)
  All values -> allM (\value -> evaluateExpr snapshot value row) values
  Any values -> anyM (\value -> evaluateExpr snapshot value row) values
  Not value -> not <$> evaluateExpr snapshot value row
  Quantified quantifier relation condition -> do
    let (key, get) = manyDescriptor relation
    children <- first (RelationshipLookupFailed key) (get snapshot row)
    case quantifier of
      Some -> anyM (evaluateExpr snapshot condition) children
      Every -> allM (evaluateExpr snapshot condition) children
      None -> not <$> anyM (evaluateExpr snapshot condition) children
  Related relation condition -> do
    let (key, get) = oneDescriptor relation
    child <- first (RelationshipLookupFailed key) (get snapshot row)
    evaluateExpr snapshot condition child
  OptionalRelated relation condition -> do
    let (key, get) = optionalDescriptor relation
    child <- first (RelationshipLookupFailed key) (get snapshot row)
    maybe (Right False) (evaluateExpr snapshot condition) child

someFieldKey :: F.SomeField -> Text
someFieldKey (F.SomeField field) = F.fieldKey field

orderField :: Order row -> F.SomeField
orderField (Order _ field) = F.SomeField field

numberRequirement :: NumberField row -> F.SomeField
numberRequirement = \case
  IntegerField field -> F.SomeField field
  DimensionField field -> F.SomeField field
  PaneIndexField field -> F.SomeField field
  WindowIndexField field -> F.SomeField field

exprRequirements :: Expr row -> ([F.SomeField], Set Text)
exprRequirements = \case
  Equal field _ -> ([F.SomeField field], Set.empty)
  OneOf field _ -> ([F.SomeField field], Set.empty)
  Contains field _ -> ([F.SomeField field], Set.empty)
  NumberCompare field _ _ -> ([numberRequirement field], Set.empty)
  All values -> foldMap exprRequirements values
  Any values -> foldMap exprRequirements values
  Not value -> exprRequirements value
  Quantified _ relation condition -> withRelationship (fst (manyDescriptor relation)) (exprRequirements condition)
  Related relation condition -> withRelationship (fst (oneDescriptor relation)) (exprRequirements condition)
  OptionalRelated relation condition -> withRelationship (fst (optionalDescriptor relation)) (exprRequirements condition)
  where
    withRelationship key (fields, relationships) = (fields, Set.insert key relationships)

numberValue :: NumberField row -> row -> Integer
numberValue field row = case field of
  IntegerField value -> F.project value row
  DimensionField value -> V.dimensionValue (F.project value row)
  PaneIndexField value -> V.paneIndexValue (F.project value row)
  WindowIndexField value -> V.windowIndexValue (F.project value row)

compareNumber :: Comparison -> Integer -> Integer -> Bool
compareNumber = \case AtLeast -> (>=); Above -> (>); AtMost -> (<=); Below -> (<)

compareRows :: [Order row] -> row -> row -> Ordering
compareRows orders left right = foldMap compareField orders
  where
    compareField (Order reversed field)
      | reversed = compare (F.project field right) (F.project field left)
      | otherwise = compare (F.project field left) (F.project field right)

takeNatural :: Natural -> [row] -> [row]
takeNatural 0 _ = []
takeNatural _ [] = []
takeNatural count (row : rows) = row : takeNatural (count - 1) rows

allM :: (value -> Either problem Bool) -> [value] -> Either problem Bool
allM _ [] = Right True
allM predicate (value : values) = do
  matched <- predicate value
  if matched then allM predicate values else Right False

anyM :: (value -> Either problem Bool) -> [value] -> Either problem Bool
anyM _ [] = Right False
anyM predicate (value : values) = do
  matched <- predicate value
  if matched then Right True else anyM predicate values

sourceKey :: Source row -> Text
sourceKey = \case
  Sessions -> "sessions"
  Windows -> "windows"
  Panes -> "panes"
  WindowLinksSource -> "windowLinks"
  Occurrences -> "paneOccurrences"
  Clients -> "clients"
  ServerInfo -> "serverInfo"

sourceRows :: G.Snapshot -> Source row -> [row]
sourceRows snapshot = \case
  Sessions -> G.graphSessions graph
  Windows -> G.graphWindows graph
  Panes -> G.graphPanes graph
  WindowLinksSource -> G.graphLinks graph
  Occurrences -> G.graphOccurrences graph
  Clients -> G.clients snapshot
  ServerInfo -> [G.serverInfo snapshot]
  where graph = G.entities snapshot

-- Each closed descriptor owns both its stable identity and its navigation.
manyDescriptor :: ToMany parent child -> (Text, G.Snapshot -> parent -> Either G.LookupError [child])
manyDescriptor = \case
  SessionLinks -> ("session.windowLinks", \snapshot row -> G.linksForSession (G.entities snapshot) row.ref)
  SessionClients -> ("session.clients", \snapshot row -> Right
    [ client | client <- G.clients snapshot, Just attachment <- [client.attachment]
    , attachment.session.ref == row.ref ])
  WindowPanes -> ("window.panes", \snapshot row -> G.panesForWindow (G.entities snapshot) row.ref)
  WindowLinks -> ("window.windowLinks", \snapshot row -> do
    _ <- G.lookupWindow (G.entities snapshot) row.ref
    Right [link | link <- G.graphLinks (G.entities snapshot), link.window == row.ref])
  LinkPanes -> ("windowLink.panes", \snapshot row -> G.panesForWindow (G.entities snapshot) row.window)

oneDescriptor :: ToOne parent child -> (Text, G.Snapshot -> parent -> Either G.LookupError child)
oneDescriptor = \case
  PaneWindow -> ("pane.window", \snapshot row -> G.lookupWindow (G.entities snapshot) row.window)
  LinkSession -> ("windowLink.session", \snapshot row -> G.lookupSession (G.entities snapshot) row.session)
  LinkWindow -> ("windowLink.window", \snapshot row -> G.lookupWindow (G.entities snapshot) row.window)
  OccurrencePane -> ("paneOccurrence.pane", \_ row -> Right row.pane)
  OccurrenceLink -> ("paneOccurrence.link", \_ row -> Right row.link)
  AttachmentSession -> ("clientAttachment.session", \_ row -> Right row.session)
  AttachmentWindow -> ("clientAttachment.window", \_ row -> Right row.window)
  AttachmentPane -> ("clientAttachment.pane", \_ row -> Right row.pane)

optionalDescriptor :: ToOptional parent child -> (Text, G.Snapshot -> parent -> Either G.LookupError (Maybe child))
optionalDescriptor = \case
  ClientAttachment -> ("client.attachment", \_ row -> Right row.attachment)
