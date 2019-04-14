{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Yesod.Page
  ( withPage
  , withEntityPage
  , Page(..)
  , Cursor(..)
  )
where

import Control.Monad (guard)
import Control.Monad.Free (Free(Free, Pure))
import Data.Aeson
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as BSL
import Data.Monoid (Last(Last, getLast), getSum)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Database.Persist
import Yesod.Core (MonadHandler, lookupGetParam)
import Yesod.Page.QueryParam.Internal

withEntityPage
  :: ( MonadHandler m
     , ToJSON (Key a)
     , FromJSON (Key a)
     , ToJSON params
     , FromJSON params
     )
  => Free ParseParam params
  -> (Cursor params (Key a) -> m [Entity a])
  -> m (Page (Entity a))
withEntityPage parse = withPage parse (\x -> (entityKey x, x))

withPage
  :: ( MonadHandler m
     , ToJSON position
     , FromJSON position
     , ToJSON params
     , FromJSON params
     )
  => Free ParseParam params
  -> (a -> (position, b))
  -> (Cursor params position -> m [a])
  -> m (Page b)
withPage parse makePayload go = do
  (cursor, with) <- getPaginated parse
  with makePayload <$> go cursor

data Page a = Page
  { pageData :: [a]
  , pageCursor :: Maybe (Cursor Value Value)
  }
  deriving (Functor)

instance ToJSON a => ToJSON (Page a) where
  toJSON p = object
    [ "data" .= pageData p
    , "next" .= pageCursor p
    ]

data Cursor params position = Cursor
  { cursorParams :: params
  , cursorLastPosition :: Maybe position
  , cursorLimit :: Maybe Int
  }

instance ToJSON (Cursor Value Value) where
  toJSON c = toJSON . decodeUtf8 . Base64.encode . BSL.toStrict . encode $ object
    [ "params" .= cursorParams c
    , "lastPosition" .= cursorLastPosition c
    , "limit" .= cursorLimit c
    ]

instance (FromJSON a, FromJSON b) => FromJSON (Cursor a b) where
  parseJSON = withText "Cursor" $ \t ->
    case Base64.decode $ encodeUtf8 t of
      Left err -> fail err
      Right rawJson -> case eitherDecode $ BSL.fromStrict rawJson of
        Left err -> fail err
        Right value -> withObject "Cursor" parseCursor value
   where
    parseCursor o = Cursor
      <$> o .: "params"
      <*> (Just <$> o .: "lastPosition")
      <*> (o .:? "limit")

getPaginated
  :: ( MonadHandler m
     , ToJSON position
     , FromJSON position
     , ToJSON params
     , FromJSON params
     )
  => Free ParseParam params
  -> m (Cursor params position, (a -> (position, b)) -> [a] -> Page b)
getPaginated parser = do
  cursor <- runParseParams parser
  pure (cursor, withCursor cursor)

withCursor
  :: (ToJSON params, ToJSON position)
  => Cursor params position
  -> (a -> (position, b))
  -> [a]
  -> Page b
withCursor cursor makePayload items = Page
  { pageData = payload
  , pageCursor = do
    guard . not $ null items || maybe False (len <) (cursorLimit cursor)
    Just $ Cursor
      { cursorParams = toJSON $ cursorParams cursor
      , cursorLastPosition = Just $ toJSON mLastId
      , cursorLimit = cursorLimit cursor
      }
  }
 where
  ((mLastId, payload), len) = unwrap $ foldMap ((, 1) . wrap) items
  wrap = bimap (Last . Just) (:) . makePayload
  unwrap = bimap (bimap getLast ($ [])) getSum

runParseParams
  :: (MonadHandler m, FromJSON b, FromJSON position)
  => Free ParseParam b
  -> m (Cursor b position)
runParseParams f = lookupGetParam "next" >>= \case
  Nothing -> do
    params <- interpret f
    limit <- (decodeText =<<) <$> lookupGetParam "limit"
    pure $ Cursor params Nothing limit
  Just next -> case eitherDecodeText $ "\"" <> next <> "\"" of
    Left err -> error err
    Right cursor -> pure cursor
 where
  interpret = \case
    (Free (LookupGetParam param next)) ->
      interpret . next =<< lookupGetParam param
    (Free (ParseParamError err _)) -> error $ show err
    (Pure x) -> pure x