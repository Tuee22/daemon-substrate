module Daemon.MinIO.Cache where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (minimumBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Set (Set)
import qualified Data.Set as Set
import Daemon.MinIO

data Cache = Cache
  { cacheQuotaBytes :: Int,
    cacheObjects :: TVar (Map ObjectRef ByteString),
    cachePins :: TVar (Set ObjectRef),
    cacheAccess :: TVar (Map ObjectRef Int),
    cacheTick :: TVar Int
  }

newCache :: Int -> IO Cache
newCache quotaBytes =
  Cache quotaBytes
    <$> newTVarIO mempty
    <*> newTVarIO mempty
    <*> newTVarIO mempty
    <*> newTVarIO 0

readWithCache :: (HasMinIO m, MonadIO m) => Cache -> ObjectRef -> m (Either MinIOError ByteString)
readWithCache cache ref = do
  cached <-
    atomicallyLift do
      objects <- readTVar (cacheObjects cache)
      case Map.lookup ref objects of
        Nothing -> pure Nothing
        Just bytes -> do
          touch cache ref
          pure (Just bytes)
  case cached of
    Just bytes -> pure (Right bytes)
    Nothing -> do
      fetched <- minioGet ref
      case fetched of
        Left err -> pure (Left err)
        Right body -> do
          atomicallyLift do
            objects <- readTVar (cacheObjects cache)
            pins <- readTVar (cachePins cache)
            access <- readTVar (cacheAccess cache)
            touch cache ref
            accessAfterTouch <- readTVar (cacheAccess cache)
            let (objects', access') =
                  pruneToQuota
                    (cacheQuotaBytes cache)
                    pins
                    (Map.insert ref (objectBodyBytes body) objects)
                    (Map.union accessAfterTouch access)
            writeTVar (cacheObjects cache) objects'
            writeTVar (cacheAccess cache) access'
          pure (Right (objectBodyBytes body))

pin :: (MonadIO m) => Cache -> ObjectRef -> m ()
pin cache ref =
  atomicallyLift do
    pins <- readTVar (cachePins cache)
    writeTVar (cachePins cache) (Set.insert ref pins)

unpin :: (MonadIO m) => Cache -> ObjectRef -> m ()
unpin cache ref =
  atomicallyLift do
    pins <- readTVar (cachePins cache)
    writeTVar (cachePins cache) (Set.delete ref pins)

isPinned :: (MonadIO m) => Cache -> ObjectRef -> m Bool
isPinned cache ref =
  atomicallyLift do
    Set.member ref <$> readTVar (cachePins cache)

pruneToQuota :: Int -> Set ObjectRef -> Map ObjectRef ByteString -> Map ObjectRef Int -> (Map ObjectRef ByteString, Map ObjectRef Int)
pruneToQuota quota pins objects access
  | totalSize objects <= quota = objects
      `withAccess` access
  | otherwise =
      case filter (not . (`Set.member` pins) . fst) (Map.toAscList objects) of
        [] -> objects `withAccess` access
        candidates ->
          let victim = fst (minimumBy (comparing (lookupAccess access . fst)) candidates)
           in pruneToQuota quota pins (Map.delete victim objects) (Map.delete victim access)

totalSize :: Map ObjectRef ByteString -> Int
totalSize = sum . fmap ByteString.length . Map.elems

atomicallyLift :: (MonadIO m) => STM a -> m a
atomicallyLift = liftIO . atomically

touch :: Cache -> ObjectRef -> STM ()
touch cache ref = do
  tick <- readTVar (cacheTick cache)
  let nextTick = tick + 1
  writeTVar (cacheTick cache) nextTick
  access <- readTVar (cacheAccess cache)
  writeTVar (cacheAccess cache) (Map.insert ref nextTick access)

lookupAccess :: Map ObjectRef Int -> ObjectRef -> Int
lookupAccess access ref = Map.findWithDefault 0 ref access

withAccess :: Map ObjectRef ByteString -> Map ObjectRef Int -> (Map ObjectRef ByteString, Map ObjectRef Int)
withAccess objects access = (objects, Map.intersection access objects)
