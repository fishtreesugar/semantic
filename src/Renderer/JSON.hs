{-# LANGUAGE OverloadedStrings, TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Renderer.JSON (
  json
) where

import Prologue hiding (toList)
import Alignment
import Category
import Data.Aeson hiding (json)
import Data.Bifunctor.Join
import Data.ByteString.Builder
import Data.Record
import qualified Data.Text as T
import Data.These
import Data.Vector hiding (toList)
import Info
import Range
import Renderer
import Source hiding (fromList)
import SplitDiff
import Syntax
import Term

-- | Render a diff to a string representing its JSON.
json :: (HasField fields Category, HasField fields Range) => Renderer (Record fields)
json diff sources = toS . toLazyByteString . fromEncoding . pairs $ "rows" .= annotateRows (alignDiff (source <$> sources) diff) <> "oids" .= (oid <$> sources) <> "paths" .= (path <$> sources)
  where annotateRows = fmap (fmap NumberedLine) . numberedRows

newtype NumberedLine a = NumberedLine (Int, a)

instance (HasField fields Category, HasField fields Range) => ToJSON (NumberedLine (SplitDiff leaf (Record fields))) where
  toJSON (NumberedLine (n, a)) = object (lineFields n a (getRange a))
  toEncoding (NumberedLine (n, a)) = pairs $ mconcat (lineFields n a (getRange a))
instance ToJSON Category where
  toJSON (Other s) = String $ T.pack s
  toJSON s = String . T.pack $ show s
instance ToJSON Range where
  toJSON (Range start end) = Array . fromList $ toJSON <$> [ start, end ]
  toEncoding (Range start end) = foldable [ start,  end ]
instance ToJSON a => ToJSON (Join These a) where
  toJSON (Join vs) = Array . fromList $ toJSON <$> these pure pure (\ a b -> [ a, b ]) vs
  toEncoding = foldable
instance ToJSON a => ToJSON (Join (,) a) where
  toJSON (Join (a, b)) = Array . fromList $ toJSON <$> [ a, b ]
  toEncoding = foldable
instance (HasField fields Category, HasField fields Range) => ToJSON (SplitDiff leaf (Record fields)) where
  toJSON splitDiff = case runFree splitDiff of
    (Free (info :< syntax)) -> object (termFields info syntax)
    (Pure patch)            -> object (patchFields patch)
  toEncoding splitDiff = case runFree splitDiff of
    (Free (info :< syntax)) -> pairs $ mconcat (termFields info syntax)
    (Pure patch)            -> pairs $ mconcat (patchFields patch)
instance (HasField fields Category, HasField fields Range) => ToJSON (Term leaf (Record fields)) where
  toJSON term     | (info :< syntax) <- runCofree term = object (termFields info syntax)
  toEncoding term | (info :< syntax) <- runCofree term = pairs $ mconcat (termFields info syntax)

lineFields :: (HasField fields Category, HasField fields Range) => KeyValue kv => Int -> SplitDiff leaf (Record fields) -> Range -> [kv]
lineFields n term range = [ "number" .= n
                          , "terms" .= [ term ]
                          , "range" .= range
                          , "hasChanges" .= hasChanges term
                          ]

termFields :: (ToJSON recur, KeyValue kv, HasField fields Category, HasField fields Range) => Record fields -> Syntax leaf recur -> [kv]
termFields info syntax = "range" .= characterRange info : "category" .= category info : case syntax of
  Leaf _ -> []
  Indexed c -> childrenFields c
  Fixed c -> childrenFields c
  where childrenFields c = [ "children" .= c ]

patchFields :: (KeyValue kv, HasField fields Category, HasField fields Range) => SplitPatch (Term leaf (Record fields)) -> [kv]
patchFields patch = case patch of
  SplitInsert term -> fields "insert" term
  SplitDelete term -> fields "delete" term
  SplitReplace term -> fields "replace" term
  where fields kind term | (info :< syntax) <- runCofree term = "patch" .= T.pack kind : termFields info syntax