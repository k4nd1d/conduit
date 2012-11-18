{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
-- | Higher-level functions to interact with the elements of a stream. Most of
-- these are based on list functions.
--
-- Note that these functions all deal with individual elements of a stream as a
-- sort of \"black box\", where there is no introspection of the contained
-- elements. Values such as @ByteString@ and @Text@ will likely need to be
-- treated specially to deal with their contents properly (@Word8@ and @Char@,
-- respectively). See the "Data.Conduit.Binary" and "Data.Conduit.Text"
-- modules.
module Data.Conduit.List
    ( -- * Sources
      sourceList
    , sourceNull
    , unfold
    , enumFromTo
    , iterate
      -- * Sinks
      -- ** Pure
    , fold
    , foldMap
    , take
    , drop
    , head
    , peek
    , consume
    , sinkNull
      -- ** Monadic
    , foldM
    , mapM_
      -- * Conduits
      -- ** Pure
    , map
    , mapMaybe
    , catMaybes
    , concatMap
    , concatMapAccum
    , groupBy
    , isolate
    , filter
      -- ** Monadic
    , mapM
    , mapMaybeM
    , concatMapM
    , concatMapAccumM
      -- * Misc
    , sequence
    ) where

import qualified Prelude
import Prelude
    ( ($), return, (==), (-), Int
    , (.), id, Maybe (..), Monad
    , Bool (..)
    , (>>)
    , (>>=)
    , seq
    , otherwise
    , Enum (succ), Eq
    , maybe
    , either
    )
import Data.Monoid (Monoid, mempty, mappend)
import Data.Conduit hiding (Source, Sink, Conduit, Pipe)
import Data.Conduit.Internal (pipe)
import Control.Monad (when, (<=<))
import Control.Monad.Trans.Class (MonadTrans, lift)

sourceList :: Yield m => [YieldOutput m] -> m ()
sourceList = Prelude.mapM_ yield

-- | Generate a source from a seed value.
--
-- Since 0.4.2
unfold :: Yield m
       => (b -> Maybe (YieldOutput m, b))
       -> b
       -> m ()
unfold f =
    go
  where
    go seed =
        case f seed of
            Just (a, seed') -> yield a >> go seed'
            Nothing -> return ()

-- | Enumerate from a value to a final value, inclusive, via 'succ'.
--
-- This is generally more efficient than using @Prelude@\'s @enumFromTo@ and
-- combining with @sourceList@ since this avoids any intermediate data
-- structures.
--
-- Since 0.4.2
enumFromTo :: (Enum a, Eq a, Yield m, a ~ YieldOutput m)
           => a
           -> a
           -> m ()
enumFromTo start stop =
    go start
  where
    go i
        | i == stop = yield i
        | otherwise = yield i >> go (succ i)

-- | Produces an infinite stream of repeated applications of f to x.
iterate :: (Yield m, YieldOutput m ~ a)
        => (a -> a)
        -> a
        -> m ()
iterate f =
    go
  where
    go a = yield a >> go (f a)

-- | A strict left fold.
--
-- Since 0.3.0
fold :: Await m
     => (b -> AwaitInput m -> b)
     -> b
     -> m b
fold f =
    loop
  where
    loop accum =
        await >>= maybe (return accum) go
      where
        go a =
            let accum' = f accum a
             in accum' `seq` loop accum'

-- | A monadic strict left fold.
--
-- Since 0.3.0
foldM :: (Await (t m), Monad m, MonadTrans t)
      => (b -> AwaitInput (t m) -> m b)
      -> b
      -> t m b
foldM f =
    loop
  where
    loop accum = do
        await >>= maybe (return accum) go
      where
        go a = do
            accum' <- lift $ f accum a
            accum' `seq` loop accum'

-- | A monoidal strict left fold.
--
-- Since 0.5.3
foldMap :: (Monad m, Monoid b, Await m)
        => (AwaitInput m -> b)
        -> m b
foldMap f =
    fold combiner mempty
  where
    combiner accum = mappend accum . f

-- | Apply the action to all values in the stream.
--
-- Since 0.3.0
mapM_ :: (Await (t m), Monad m, MonadTrans t)
      => (AwaitInput (t m) -> m ())
      -> t m (AwaitTerm (t m))
mapM_ f = awaitForever $ lift . f

-- | Ignore a certain number of values in the stream. This function is
-- semantically equivalent to:
--
-- > drop i = take i >> return ()
--
-- However, @drop@ is more efficient as it does not need to hold values in
-- memory.
--
-- Since 0.3.0
drop :: Await m
     => Int
     -> m ()
drop =
    loop
  where
    loop 0 = return ()
    loop count = await >>= maybe (return ()) (\_ -> loop (count - 1))

-- | Take some values from the stream and return as a list. If you want to
-- instead create a conduit that pipes data to another sink, see 'isolate'.
-- This function is semantically equivalent to:
--
-- > take i = isolate i =$ consume
--
-- Since 0.3.0
take :: Await m
     => Int
     -> m [AwaitInput m]
take =
    loop id
  where
    loop front 0 = return $ front []
    loop front count = await >>= maybe
        (return $ front [])
        (\x -> loop (front .(x:)) (count - 1))

-- | Take a single value from the stream, if available.
--
-- Since 0.3.0
head :: Await m
     => m (Maybe (AwaitInput m))
head = await

-- | Look at the next value in the stream, if available. This function will not
-- change the state of the stream.
--
-- Since 0.3.0
peek :: Await m
     => m (Maybe (AwaitInput m))
peek = await >>= maybe (return Nothing) (\x -> leftover x >> return (Just x))

-- | Apply a transformation to all values in a stream.
--
-- Since 0.3.0
map :: (Yield m, Await m)
    => (AwaitInput m -> YieldOutput m)
    -> m (AwaitTerm m)
map f = awaitForever $ yield . f

{-

It might be nice to include these rewrite rules, but they may have subtle
differences based on leftovers.

{-# RULES "map-to-mapOutput $=" forall f src. src $= (map f) = mapOutput f src #-}
{-# RULES "map-to-mapOutput pipe" forall f src. pipe src (map f) = mapOutput f src #-}
{-# RULES "map-to-mapOutput >+>" forall f src. src >+> (map f) = mapOutput f src #-}

{-# RULES "map-to-mapInput =$" forall f sink. map f =$ sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}
{-# RULES "map-to-mapInput pipe" forall f sink. pipe (map f) sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}
{-# RULES "map-to-mapInput >+>" forall f sink. map f >+> sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}

{-# RULES "map-to-mapOutput =$=" forall f con. con =$= map f = mapOutput f con #-}
{-# RULES "map-to-mapInput =$=" forall f con. map f =$= con = mapInput f (Prelude.const Prelude.Nothing) con #-}

{-# INLINE [1] map #-}

-}

-- | Apply a monadic transformation to all values in a stream.
--
-- If you do not need the transformed values, and instead just want the monadic
-- side-effects of running the action, see 'mapM_'.
--
-- Since 0.3.0
mapM :: (MonadTrans t, Yield (t m), Await (t m), Monad m)
     => (AwaitInput (t m) -> m (YieldOutput (t m)))
     -> t m (AwaitTerm (t m))
mapM f = awaitForever $ yield <=< lift . f

-- | Apply a transformation that may fail to all values in a stream, discarding
-- the failures.
--
-- Since 0.5.1
mapMaybe :: (Await m, Yield m)
         => (AwaitInput m -> Maybe (YieldOutput m))
         -> m (AwaitTerm m)
mapMaybe f = awaitForever $ maybe (return ()) yield . f

-- | Apply a monadic transformation that may fail to all values in a stream,
-- discarding the failures.
--
-- Since 0.5.1
mapMaybeM :: (Await (t m), Yield (t m), Monad m, MonadTrans t)
          => (AwaitInput (t m) -> m (Maybe (YieldOutput (t m))))
          -> t m (AwaitTerm (t m))
mapMaybeM f = awaitForever $ maybe (return ()) yield <=< lift . f

-- | Filter the @Just@ values from a stream, discarding the @Nothing@  values.
--
-- Since 0.5.1
catMaybes :: (Yield m, AwaitInput m ~ Maybe (YieldOutput m), Await m)
          => m (AwaitTerm m)
catMaybes = awaitForever $ maybe (return ()) yield

-- | Apply a transformation to all values in a stream, concatenating the output
-- values.
--
-- Since 0.3.0
concatMap :: (Yield m, Await m)
          => (AwaitInput m -> [YieldOutput m])
          -> m (AwaitTerm m)
concatMap f = awaitForever $ Prelude.mapM_ yield . f

-- | Apply a monadic transformation to all values in a stream, concatenating
-- the output values.
--
-- Since 0.3.0
concatMapM :: (Yield (t m), Await (t m), Monad m, MonadTrans t)
           => (AwaitInput (t m) -> m [YieldOutput (t m)])
           -> t m (AwaitTerm (t m))
concatMapM f = awaitForever $ Prelude.mapM_ yield <=< lift . f

-- | 'concatMap' with an accumulator.
--
-- Since 0.3.0
concatMapAccum :: (Yield m, Await m)
               => (AwaitInput m -> accum -> (accum, [YieldOutput m]))
               -> accum
               -> m (AwaitTerm m)
concatMapAccum f =
    loop
  where
    loop accum =
        awaitE >>= either return go
      where
        go a = do
            let (accum', bs) = f a accum
            Prelude.mapM_ yield bs
            loop accum'

-- | 'concatMapM' with an accumulator.
--
-- Since 0.3.0
concatMapAccumM :: (Yield (t m), Await (t m), Monad m, MonadTrans t)
                => (AwaitInput (t m) -> accum -> m (accum, [YieldOutput (t m)]))
                -> accum
                -> t m (AwaitTerm (t m))
concatMapAccumM f =
    loop
  where
    loop accum = do
        awaitE >>= either return go
      where
        go a = do
            (accum', bs) <- lift $ f a accum
            Prelude.mapM_ yield bs
            loop accum'

-- | Consume all values from the stream and return as a list. Note that this
-- will pull all values into memory. For a lazy variant, see
-- "Data.Conduit.Lazy".
--
-- Since 0.3.0
consume :: Await m
        => m [AwaitInput m]
consume =
    loop id
  where
    loop front = await >>= maybe (return $ front []) (\x -> loop $ front . (x:))

-- | Grouping input according to an equality function.
--
-- Since 0.3.0
groupBy :: ([AwaitInput m] ~ YieldOutput m, Await m, Yield m)
        => (AwaitInput m -> AwaitInput m -> Bool)
        -> m (AwaitTerm m)
groupBy f =
    start
  where
    start = awaitE >>= either return (loop id)

    loop rest x =
        awaitE >>= either (\r -> yield (x : rest []) >> return r) go
      where
        go y
            | f x y     = loop (rest . (y:)) x
            | otherwise = yield (x : rest []) >> loop id y

-- | Ensure that the inner sink consumes no more than the given number of
-- values. Note this this does /not/ ensure that the sink consumes all of those
-- values. To get the latter behavior, combine with 'sinkNull', e.g.:
--
-- > src $$ do
-- >     x <- isolate count =$ do
-- >         x <- someSink
-- >         sinkNull
-- >         return x
-- >     someOtherSink
-- >     ...
--
-- Since 0.3.0
isolate :: (YieldOutput m ~ AwaitInput m, Yield m, Await m)
        => Int
        -> m ()
isolate =
    loop
  where
    loop 0 = return ()
    loop count = await >>= maybe (return ()) (\x -> yield x >> loop (count - 1))

-- | Keep only values in the stream passing a given predicate.
--
-- Since 0.3.0
filter :: (AwaitInput m ~ YieldOutput m, Yield m, Await m)
       => (AwaitInput m -> Bool)
       -> m (AwaitTerm m)
filter f = awaitForever $ \i -> when (f i) (yield i)

-- | Ignore the remainder of values in the source. Particularly useful when
-- combined with 'isolate'.
--
-- Since 0.3.0
sinkNull :: Await m
         => m (AwaitTerm m)
sinkNull = awaitForever $ \_ -> return ()

-- | A source that outputs no values. Note that this is just a type-restricted
-- synonym for 'mempty'.
--
-- Since 0.3.0
sourceNull :: Yield m
           => m ()
sourceNull = return ()

-- | Run a @Pipe@ repeatedly, and output its result value downstream. Stops
-- when no more input is available from upstream.
--
-- Since 0.5.0
sequence :: (Yield m, Await m)
         => m (YieldOutput m)
         -> m (AwaitTerm m)
sequence sink =
    self
  where
    self = awaitForever $ \i -> leftover i >> sink >>= yield
