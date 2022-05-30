{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}
module Analysis.Syntax
( Term(..)
  -- * Abstract interpretation
, eval0
, eval
  -- * Macro-expressible syntax
, let'
, letrec
  -- * Parsing
, parseFile
, parseGraph
, parseNode
) where

import qualified Analysis.Carrier.Statement.State as S
import           Analysis.Effect.Domain
import           Analysis.Effect.Env (Env, bind, lookupEnv)
import           Analysis.Effect.Store
import           Analysis.File
import           Analysis.Name (Name, name)
import           Analysis.Reference as Ref
import           Control.Applicative (Alternative (..), liftA2, liftA3)
import           Control.Effect.Labelled
import           Control.Effect.Reader
import           Control.Effect.Throw (Throw, throwError)
import           Control.Monad (guard)
import           Control.Monad.IO.Class
import qualified Data.Aeson as A
import qualified Data.Aeson.Internal as A
import qualified Data.Aeson.Parser as A
import qualified Data.Aeson.Types as A
import qualified Data.ByteString.Lazy as B
import           Data.Foldable (fold, foldl')
import           Data.Function (fix)
import qualified Data.IntMap as IntMap
import           Data.List (sortOn)
import           Data.List.NonEmpty (NonEmpty, fromList)
import           Data.Monoid (First (..))
import           Data.String (IsString (..))
import           Data.Text (Text)
import qualified Data.Vector as V
import qualified Source.Source as Source
import           Source.Span
import qualified System.Path as Path

data Term
  = Var Name
  | Noop
  | Iff Term Term Term
  | Bool Bool
  | String Text
  | Throw Term
  | Let Name Term Term
  | Term :>> Term
  | Import (NonEmpty Text)
  | Function Name [Name] Term
  | Call Term [Term]
  | Locate Reference Term
  deriving (Eq, Ord, Show)

infixl 1 :>>


-- Abstract interpretation

eval0 :: (Has (Env addr) sig m, HasLabelled Store (Store addr val) sig m, Has (Dom val) sig m, Has (Reader Reference) sig m, Has S.Statement sig m) => Term -> m val
eval0 = fix eval

eval
  :: (Has (Env addr) sig m, HasLabelled Store (Store addr val) sig m, Has (Dom val) sig m, Has (Reader Reference) sig m, Has S.Statement sig m)
  => (Term -> m val)
  -> (Term -> m val)
eval eval = \case
  Var n     -> lookupEnv n >>= maybe (dvar n) fetch
  Noop      -> dunit
  Iff c t e -> do
    c' <- eval c
    dif c' (eval t) (eval e)
  Bool b    -> dbool b
  String s  -> dstring s
  Throw e   -> eval e >>= ddie
  Let n v b -> do
    v' <- eval v
    let' n v' (eval b)
  t :>> u   -> do
    t' <- eval t
    u' <- eval u
    t' >>> u'
  Import ns -> S.simport ns >> dunit
  Function n ps b -> letrec n (dabs ps (\ as ->
    foldr (\ (p, a) m -> let' p a m) (eval b) (zip ps as)))
  Call f as -> do
    f' <- eval f
    as' <- traverse eval as
    dapp f' as'
  Locate ref t -> local (const ref) (eval t)


-- Macro-expressible syntax

let' :: (Has (Env addr) sig m, HasLabelled Store (Store addr val) sig m) => Name -> val -> m a -> m a
let' n v m = do
  addr <- alloc n
  addr .= v
  bind n addr m

letrec :: (Has (Env addr) sig m, HasLabelled Store (Store addr val) sig m) => Name -> m val -> m val
letrec n m = do
  addr <- alloc n
  v <- bind n addr m
  addr .= v
  pure v


-- Parsing

parseFile :: (Has (Throw String) sig m, MonadIO m) => FilePath -> m (File Term)
parseFile path = do
  contents <- liftIO (B.readFile path)
  let span = Source.totalSpan (Source.fromUTF8 (B.toStrict contents))
      path' = Path.absRel path
  case (A.eitherDecodeWith A.json' (A.iparse (parseGraph path')) contents) of
    Left  (_, err)       -> throwError err
    Right (_, Nothing)   -> throwError "no root node found"
    -- FIXME: this should get the path to the source file, not the path to the JSON.
    Right (_, Just root) -> pure (File (Reference path' span) root)

newtype Graph = Graph { terms :: IntMap.IntMap Term }

-- | Parse a @Value@ into an entire graph of terms, as well as a root node, if any exists.
parseGraph :: Path.AbsRelFile -> A.Value -> A.Parser (Graph, Maybe Term)
parseGraph path = A.withArray "nodes" $ \ nodes -> do
  (untied, First root) <- fold <$> traverse (parseNode path) (V.toList nodes)
  -- @untied@ is an intmap, where the keys are graph node IDs and the values are functions from the final graph to the representations of said graph nodes. Likewise, @root@ is a function of the same variety, wrapped in a @Maybe@.
  --
  -- We define @tied@ as the fixpoint of the former to yield the former as a graph of type @Graph@, and apply the latter to said graph to yield the entry point, if any, from which to evaluate.
  let tied = fix (\ tied -> ($ Graph tied) <$> untied)
  pure (Graph tied, ($ Graph tied) <$> root)

-- | Parse a node from a JSON @Value@ into a pair of a partial graph of unfixed terms and optionally an unfixed term representing the root node.
--
-- The partial graph is represented as an adjacency map relating node IDs to unfixed terms—terms which may make reference to a completed graph to find edges, and which therefore can't be inspected until the full graph is known.
parseNode :: Path.AbsRelFile -> A.Value -> A.Parser (IntMap.IntMap (Graph -> Term), First (Graph -> Term))
parseNode path = A.withObject "node" $ \ o -> do
  edges <- o A..: fromString "edges"
  index <- o A..: fromString "id"
  o A..: fromString "attrs" >>= A.withObject "attrs" (\ attrs -> do
    ty <- attrs A..: fromString "type"
    node <- parseTerm path attrs edges ty
    pure (IntMap.singleton index node, node <$ First (guard (ty == "module"))))

parseTerm :: Path.AbsRelFile -> A.Object -> [A.Value] -> String -> A.Parser (Graph -> Term)
parseTerm _ attrs edges = \case
  "string"     -> const . String <$> attrs A..: fromString "text"
  "true"       -> pure (const (Bool True))
  "false"      -> pure (const (Bool False))
  "throw"      -> fmap Throw <$> resolve (head edges)
  "if"         -> liftA3 Iff <$> findEdgeNamed edges "condition" <*> findEdgeNamed edges "consequence" <*> findEdgeNamed edges "alternative" <|> pure (const Noop)
  "block"      -> children edges
  "module"     -> children edges
  "identifier" -> const . Var . name <$> attrs A..: fromString "text"
  "import"     -> const . Import . fromList . map snd . sortOn fst <$> traverse (resolveWith (const moduleNameComponent)) edges
  "function"   -> liftA3 Function . pure . name <$> attrs A..: fromString "name" <*> pure (pure []) <*> findEdgeNamed edges "body"
  "call"       -> liftA2 Call . const . Var . name <$> attrs A..: fromString "function" <*> (sequenceA <$> traverse resolve edges)
  "noop"       -> pure (pure Noop)
  t            -> A.parseFail ("unrecognized type: " <> t <> " attrs: " <> show attrs <> " edges: " <> show edges)

findEdgeNamed :: (Foldable t, A.FromJSON a, Eq a) => t A.Value -> a -> A.Parser (Graph -> Term)
findEdgeNamed edges name = foldMap (resolveWith (\ rep attrs -> attrs A..: fromString "type" >>= (rep <$) . guard . (== name))) edges

-- | Map a list of edges to a list of child nodes.
children :: [A.Value] -> A.Parser (Graph -> Term)
children edges = fmap (foldl' (:>>) Noop) . sequenceA . map snd . sortOn fst <$> traverse (resolveWith child) edges
  where
  child :: (Graph -> Term) -> A.Object -> A.Parser (Int, Graph -> Term)
  child term attrs = (,) <$> attrs A..: fromString "index" <*> pure term

moduleNameComponent :: A.Object -> A.Parser (Int, Text)
moduleNameComponent attrs = (,) <$> attrs A..: fromString "index" <*> attrs A..: fromString "text"

resolve :: A.Value -> A.Parser (Graph -> Term)
resolve = resolveWith (const . pure)

resolveWith :: ((Graph -> Term) -> A.Object -> A.Parser a) -> A.Value -> A.Parser a
resolveWith f = resolveWith' (f . flip ((IntMap.!) . terms))

resolveWith' :: (IntMap.Key -> A.Object -> A.Parser a) -> A.Value -> A.Parser a
resolveWith' f = A.withObject "edge" (\ edge -> do
  sink <- edge A..: fromString "sink"
  attrs <- edge A..: fromString "attrs"
  f sink attrs)
