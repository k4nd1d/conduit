{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
-- | Streaming compression and decompression using conduits.
--
-- Parts of this code were taken from zlib-enum and adapted for conduits.
module Data.Conduit.Zlib (
    -- * Conduits
    compress, decompress, gzip, ungzip,
    -- * Flushing
    compressFlush, decompressFlush,
    -- * Re-exported from zlib-bindings
    WindowBits (..), defaultWindowBits
) where

import Codec.Zlib
import Data.Conduit hiding (unsafeLiftIO, Source, Sink, Conduit, Pipe)
import qualified Data.Conduit as C (unsafeLiftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as S
import Control.Exception (try)
import Control.Monad ((<=<), unless, liftM)

-- | Gzip compression with default parameters.
gzip :: (MonadThrow m, MonadUnsafeIO m, IsPipe m, PipeInput m ~ ByteString, PipeOutput m ~ ByteString)
     => m (PipeTerm m)
gzip = compress 1 (WindowBits 31)

-- | Gzip decompression with default parameters.
ungzip :: (MonadUnsafeIO m, MonadThrow m, IsPipe m, PipeInput m ~ ByteString, PipeOutput m ~ ByteString)
       => m (PipeTerm m)
ungzip = decompress (WindowBits 31)

unsafeLiftIO :: (MonadUnsafeIO m, MonadThrow m) => IO a -> m a
unsafeLiftIO =
    either rethrow return <=< C.unsafeLiftIO . try
  where
    rethrow :: MonadThrow m => ZlibException -> m a
    rethrow = monadThrow

-- |
-- Decompress (inflate) a stream of 'ByteString's. For example:
--
-- >    sourceFile "test.z" $= decompress defaultWindowBits $$ sinkFile "test"

decompress
    :: (MonadUnsafeIO m, MonadThrow m, IsPipe m, PipeOutput m ~ ByteString, PipeInput m ~ ByteString)
    => WindowBits -- ^ Zlib parameter (see the zlib-bindings package as well as the zlib C library)
    -> m (PipeTerm m)
decompress =
    helperDecompress (liftM (fmap Chunk) awaitE) yield'
  where
    yield' Flush = return ()
    yield' (Chunk bs) = yield bs

-- | Same as 'decompress', but allows you to explicitly flush the stream.
decompressFlush
    :: (MonadUnsafeIO m, MonadThrow m, PipeOutput m ~ Flush ByteString, PipeInput m ~ Flush ByteString, IsPipe m)
    => WindowBits -- ^ Zlib parameter (see the zlib-bindings package as well as the zlib C library)
    -> m (PipeTerm m)
decompressFlush = helperDecompress awaitE yield

helperDecompress :: (MonadUnsafeIO m, MonadThrow m)
                 => m (Either term (Flush ByteString))
                 -> (Flush ByteString -> m ())
                 -> WindowBits
                 -> m term
helperDecompress awaitE' yield' config =
    awaitE' >>= either return start
  where
    start input = do
        inf <- unsafeLiftIO $ initInflate config
        push inf input

    continue inf = awaitE' >>= either (close inf) (push inf)

    goPopper popper = do
        mbs <- unsafeLiftIO popper
        case mbs of
            Nothing -> return ()
            Just bs -> yield' (Chunk bs) >> goPopper popper

    push inf (Chunk x) = do
        popper <- unsafeLiftIO $ feedInflate inf x
        goPopper popper
        continue inf

    push inf Flush = do
        chunk <- unsafeLiftIO $ flushInflate inf
        unless (S.null chunk) $ yield' $ Chunk chunk
        yield' Flush
        continue inf

    close inf ret = do
        chunk <- unsafeLiftIO $ finishInflate inf
        unless (S.null chunk) $ yield' $ Chunk chunk
        return ret

-- |
-- Compress (deflate) a stream of 'ByteString's. The 'WindowBits' also control
-- the format (zlib vs. gzip).

compress
    :: (MonadUnsafeIO m, MonadThrow m, IsPipe m, PipeOutput m ~ ByteString, PipeInput m ~ ByteString)
    => Int         -- ^ Compression level
    -> WindowBits  -- ^ Zlib parameter (see the zlib-bindings package as well as the zlib C library)
    -> m (PipeTerm m)
compress =
    helperCompress (liftM (fmap Chunk) awaitE) yield'
  where
    yield' Flush = return ()
    yield' (Chunk bs) = yield bs

-- | Same as 'compress', but allows you to explicitly flush the stream.
compressFlush
    :: (MonadUnsafeIO m, MonadThrow m, PipeOutput m ~ Flush ByteString, IsPipe m, PipeInput m ~ Flush ByteString)
    => Int         -- ^ Compression level
    -> WindowBits  -- ^ Zlib parameter (see the zlib-bindings package as well as the zlib C library)
    -> m (PipeTerm m)
compressFlush = helperCompress awaitE yield

helperCompress :: (MonadUnsafeIO m, MonadThrow m)
               => m (Either term (Flush ByteString))
               -> (Flush ByteString -> m ())
               -> Int
               -> WindowBits
               -> m term
helperCompress awaitE' yield' level config =
    awaitE' >>= either return start
  where
    start input = do
        def <- unsafeLiftIO $ initDeflate level config
        push def input

    continue def = awaitE' >>= either (close def) (push def)

    goPopper popper = do
        mbs <- unsafeLiftIO popper
        case mbs of
            Nothing -> return ()
            Just bs -> yield' (Chunk bs) >> goPopper popper

    push def (Chunk x) = do
        popper <- unsafeLiftIO $ feedDeflate def x
        goPopper popper
        continue def

    push def Flush = do
        mchunk <- unsafeLiftIO $ flushDeflate def
        maybe (return ()) (yield' . Chunk) mchunk
        yield' Flush
        continue def

    close def ret = do
        mchunk <- unsafeLiftIO $ finishDeflate def
        case mchunk of
            Nothing -> return ret
            Just chunk -> yield' (Chunk chunk) >> close def ret
