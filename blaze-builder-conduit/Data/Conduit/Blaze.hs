{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
-- | Convert a stream of blaze-builder @Builder@s into a stream of @ByteString@s.
--
-- Adapted from blaze-builder-enumerator, written by myself and Simon Meier.
--
-- Note that the functions here can work in any monad built on top of @IO@ or
-- @ST@.
module Data.Conduit.Blaze
    (

  -- * Conduits from builders to bytestrings
    builderToByteString
  , unsafeBuilderToByteString
  , builderToByteStringWith

  -- ** Flush
  , builderToByteStringFlush
  , builderToByteStringWithFlush

  -- * Buffers
  , Buffer

  -- ** Status information
  , freeSize
  , sliceSize
  , bufferSize

  -- ** Creation and modification
  , allocBuffer
  , reuseBuffer
  , nextSlice

  -- ** Conversion to bytestings
  , unsafeFreezeBuffer
  , unsafeFreezeNonEmptyBuffer

  -- * Buffer allocation strategies
  , BufferAllocStrategy
  , allNewBuffersStrategy
  , reuseBufferStrategy
    ) where

import Data.Conduit hiding (Source, Conduit, Sink, Pipe)
import Control.Monad (unless, liftM)

import qualified Data.ByteString                   as S

import Blaze.ByteString.Builder.Internal
import Blaze.ByteString.Builder.Internal.Types
import Blaze.ByteString.Builder.Internal.Buffer

-- | Incrementally execute builders and pass on the filled chunks as
-- bytestrings.
builderToByteString :: (MonadUnsafeIO m, PipeInput m ~ Builder, PipeOutput m ~ S.ByteString, IsPipe m)
                    => m (PipeTerm m)
builderToByteString =
  builderToByteStringWith (allNewBuffersStrategy defaultBufferSize)

-- |
--
-- Since 0.0.2
builderToByteStringFlush :: (MonadUnsafeIO m, IsPipe m, PipeInput m ~ Flush Builder, PipeOutput m ~ Flush S.ByteString)
                         => m (PipeTerm m)
builderToByteStringFlush =
  builderToByteStringWithFlush (allNewBuffersStrategy defaultBufferSize)

-- | Incrementally execute builders on the given buffer and pass on the filled
-- chunks as bytestrings. Note that, if the given buffer is too small for the
-- execution of a build step, a larger one will be allocated.
--
-- WARNING: This conduit yields bytestrings that are NOT
-- referentially transparent. Their content will be overwritten as soon
-- as control is returned from the inner sink!
unsafeBuilderToByteString :: (PipeOutput m ~ S.ByteString, PipeInput m ~ Builder, MonadUnsafeIO m, IsPipe m)
                          => IO Buffer  -- action yielding the inital buffer.
                          -> m (PipeTerm m)
unsafeBuilderToByteString = builderToByteStringWith . reuseBufferStrategy


-- | A conduit that incrementally executes builders and passes on the
-- filled chunks as bytestrings to an inner sink.
--
-- INV: All bytestrings passed to the inner sink are non-empty.
builderToByteStringWith :: (MonadUnsafeIO m, PipeOutput m ~ S.ByteString, PipeInput m ~ Builder, IsPipe m)
                        => BufferAllocStrategy
                        -> m (PipeTerm m)
builderToByteStringWith =
    helper (liftM (fmap Chunk) awaitE) yield'
  where
    yield' Flush = return ()
    yield' (Chunk bs) = yield bs

-- |
--
-- Since 0.0.2
builderToByteStringWithFlush
    :: (IsPipe m, PipeInput m ~ Flush Builder, PipeOutput m ~ Flush S.ByteString, MonadUnsafeIO m)
    => BufferAllocStrategy
    -> m (PipeTerm m)
builderToByteStringWithFlush = helper awaitE yield

helper :: (MonadUnsafeIO m)
       => m (Either term (Flush Builder))
       -> (Flush S.ByteString -> m ())
       -> BufferAllocStrategy
       -> m term
helper awaitE' yield' (ioBufInit, nextBuf) =
    loop ioBufInit
  where
    loop ioBuf = do
        awaitE' >>= either (close ioBuf) (cont' ioBuf)

    cont' ioBuf Flush = push ioBuf flush $ \ioBuf' -> yield' Flush >> loop ioBuf'
    cont' ioBuf (Chunk builder) = push ioBuf builder loop

    close ioBuf r = do
        buf <- unsafeLiftIO $ ioBuf
        maybe (return ()) (yield' . Chunk) (unsafeFreezeNonEmptyBuffer buf)
        return r

    push ioBuf0 x continue = do
        go (unBuilder x (buildStep finalStep)) ioBuf0
      where
        finalStep !(BufRange pf _) = return $ Done pf ()

        go bStep ioBuf = do
            !buf   <- unsafeLiftIO $ ioBuf
            signal <- unsafeLiftIO $ execBuildStep bStep buf
            case signal of
                Done op' _ -> continue $ return $ updateEndOfSlice buf op'
                BufferFull minSize op' bStep' -> do
                    let buf' = updateEndOfSlice buf op'
                        {-# INLINE cont #-}
                        cont = do
                            -- sequencing the computation of the next buffer
                            -- construction here ensures that the reference to the
                            -- foreign pointer `fp` is lost as soon as possible.
                            ioBuf' <- unsafeLiftIO $ nextBuf minSize buf'
                            go bStep' ioBuf'
                    case unsafeFreezeNonEmptyBuffer buf' of
                        Nothing -> return ()
                        Just bs -> yield' (Chunk bs)
                    cont
                InsertByteString op' bs bStep' -> do
                    let buf' = updateEndOfSlice buf op'
                    case unsafeFreezeNonEmptyBuffer buf' of
                        Nothing -> return ()
                        Just bs' -> yield' $ Chunk bs'
                    unless (S.null bs) $ yield' $ Chunk bs
                    unsafeLiftIO (nextBuf 1 buf') >>= go bStep'
