{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FunctionalDependencies #-}
module Data.Conduit.Internal
    ( -- * Types
      Pipe (..)
    , Source
    , SourceM (..)
    , Sink (..)
    , Conduit
    , ConduitM (..)
    , ResumableSource (..)
      -- * Primitives
    , IsPipe (..)
    , awaitForever
      -- * Finalization
    , ResourcePipe (..)
      -- * Composition
    , idP
    , pipe
    , connectResume
    , runPipe
    , injectLeftovers
      -- * Generalizing
    , ToPipe (..)
    , fromPipe
      -- * Utilities
    , transPipe
    , mapOutput
    , mapOutputMaybe
    , mapInput
    , sourceList
    , withUpstream
    , unwrapResumable
    ) where

import Control.Applicative (Applicative (..))
import Control.Monad ((>=>), liftM, ap, when)
import Control.Monad.Trans.Class (MonadTrans (lift))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Base (MonadBase (liftBase))
import Data.Void (Void, absurd)
import Data.Monoid (Monoid (mappend, mempty))
import Control.Monad.Trans.Resource
import Control.Monad.Trans.Control (liftWith, restoreT)
import qualified GHC.Exts
import qualified Data.IORef as I

import Control.Monad.Trans.Identity ( IdentityT)
import Control.Monad.Trans.List     ( ListT    )
import Control.Monad.Trans.Maybe    ( MaybeT   )
import Control.Monad.Trans.Error    ( ErrorT, Error)
import Control.Monad.Trans.Reader   ( ReaderT  )
import Control.Monad.Trans.State    ( StateT   )
import Control.Monad.Trans.Writer   ( WriterT  )
import Control.Monad.Trans.RWS      ( RWST     )

import qualified Control.Monad.Trans.RWS.Strict    as Strict ( RWST   )
import qualified Control.Monad.Trans.State.Strict  as Strict ( StateT )
import qualified Control.Monad.Trans.Writer.Strict as Strict ( WriterT )

import Control.Monad.State.Class  ( MonadState (..) )

-- | The underlying datatype for all the types in this package.  In has six
-- type parameters:
--
-- * /l/ is the type of values that may be left over from this @Pipe@. A @Pipe@
-- with no leftovers would use @Void@ here, and one with leftovers would use
-- the same type as the /i/ parameter. Leftovers are automatically provided to
-- the next @Pipe@ in the monadic chain.
--
-- * /i/ is the type of values for this @Pipe@'s input stream.
--
-- * /o/ is the type of values for this @Pipe@'s output stream.
--
-- * /u/ is the result type from the upstream @Pipe@.
--
-- * /m/ is the underlying monad.
--
-- * /r/ is the result type.
--
-- A basic intuition is that every @Pipe@ produces a stream of output values
-- (/o/), and eventually indicates that this stream is terminated by sending a
-- result (/r/). On the receiving end of a @Pipe@, these become the /i/ and /u/
-- parameters.
--
-- Since 0.5.0
data Pipe i o u m r =
    -- | Provide new output to be sent downstream. This constructor has three
    -- fields: the next @Pipe@ to be used, a finalization function, and the
    -- output value.
    HaveOutput (Pipe i o u m r) (m ()) o
    -- | Request more input from upstream. The first field takes a new input
    -- value and provides a new @Pipe@. The second takes an upstream result
    -- value, which indicates that upstream is producing no more results.
  | NeedInput (i -> Pipe i o u m r) (u -> Pipe i o u m r)
    -- | Processing with this @Pipe@ is complete, providing the final result.
  | Done r
    -- | Require running of a monadic action to get the next @Pipe@.
  | PipeM (m (Pipe i o u m r))
    -- | Return leftover input, which should be provided to future operations.
  | Leftover (Pipe i o u m r) i

instance Monad m => Functor (Pipe i o u m) where
    fmap = liftM

instance Monad m => Applicative (Pipe i o u m) where
    pure = return
    (<*>) = ap

instance Monad m => Monad (Pipe i o u m) where
    return = Done

    Done x           >>= fp = fp x
    HaveOutput p c o >>= fp = HaveOutput (p >>= fp)            c          o
    NeedInput p c    >>= fp = NeedInput  (p >=> fp)            (c >=> fp)
    PipeM mp         >>= fp = PipeM      ((>>= fp) `liftM` mp)
    Leftover p i     >>= fp = Leftover   (p >>= fp)            i

instance MonadBase base m => MonadBase base (Pipe i o u m) where
    liftBase = lift . liftBase

instance MonadTrans (Pipe i o u) where
    lift mr = PipeM (Done `liftM` mr)

instance MonadIO m => MonadIO (Pipe i o u m) where
    liftIO = lift . liftIO

instance MonadThrow m => MonadThrow (Pipe i o u m) where
    monadThrow = lift . monadThrow

instance MonadActive m => MonadActive (Pipe i o u m) where
    monadActive = lift monadActive

instance Monad m => Monoid (Pipe i o u m ()) where
    mempty = return ()
    mappend = (>>)
instance Monad m => Monoid (SourceM o m ()) where
    mempty = return ()
    mappend = (>>)
instance Monad m => Monoid (Sink i m ()) where
    mempty = return ()
    mappend = (>>)

-- | Provides a stream of output values, without consuming any input or
-- producing a final result.
--
-- Since 0.6.0
type Source m o = SourceM o m ()

newtype SourceM o m r = SourceM { unSourceM :: Pipe () o () m r }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, ResourcePipe, MonadThrow)

-- | Consumes a stream of input values and produces a final result, without
-- producing any output.
--
-- Since 0.6.0
newtype Sink i m r = Sink { unSink :: Pipe i Void () m r }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, ResourcePipe, MonadThrow)

-- | Consumes a stream of input values and produces a stream of output values,
-- without producing a final result.
--
-- Since 0.6.0
type Conduit i m o = ConduitM i o m ()

newtype ConduitM i o m r = ConduitM { unConduitM :: Pipe i o () m r }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, ResourcePipe, MonadThrow)

-- | A @Source@ which has been started, but has not yet completed.
--
-- This type contains both the current state of the @Source@, and the finalizer
-- to be run to close it.
--
-- Since 0.5.0
data ResumableSource m o = ResumableSource (Pipe () o () m ()) (m ())

class (Monad m, Monad (PipeMonad m)) => IsPipe m where
    type PipeInput m
    type PipeTerm m
    type PipeOutput m
    type PipeMonad m :: * -> *

    -- | Wait for a single input value from upstream, terminating immediately if no
    -- data is available.
    --
    -- Since 0.5.0
    await :: m (Maybe (PipeInput m))

    -- | This is similar to @await@, but will return the upstream result value as
    -- @Left@ if available.
    --
    -- Since 0.5.0
    awaitE :: m (Either (PipeTerm m) (PipeInput m))

    -- | Provide a single piece of leftover input to be consumed by the next pipe
    -- in the current monadic binding.
    --
    -- /Note/: it is highly encouraged to only return leftover values from input
    -- already consumed from upstream.
    --
    -- Since 0.5.0
    leftover :: PipeInput m -> m ()

    -- | Send a single output value downstream. If the downstream @Pipe@
    -- terminates, this @Pipe@ will terminate as well.
    --
    -- Since 0.5.0
    yield :: PipeOutput m -> m ()

    -- | Similar to @yield@, but additionally takes a finalizer to be run if the
    -- downstream @Pipe@ terminates.
    --
    -- Since 0.5.0
    yieldOr :: PipeOutput m -> PipeMonad m () -> m ()

    liftPipeMonad :: PipeMonad m a -> m a

    -- | Add some code to be run when the given @Pipe@ cleans up.
    --
    -- Since 0.4.1
    addCleanup :: (Bool -> PipeMonad m ()) -- ^ @True@ if @Pipe@ ran to completion, @False@ for early termination.
               -> m r
               -> m r

instance Monad m => IsPipe (Pipe i o u m) where
    type PipeInput (Pipe i o u m) = i
    type PipeTerm (Pipe i o u m) = u
    type PipeOutput (Pipe i o u m) = o
    type PipeMonad (Pipe i o u m) = m

    await = NeedInput (Done . Just) (\_ -> Done Nothing)
    {-# INLINE [1] await #-}

    awaitE = NeedInput (Done . Right) (Done . Left)
    {-# INLINE [1] awaitE #-}

    leftover = Leftover (Done ())
    {-# INLINE [1] leftover #-}

    yield = yield'
    {-# INLINE yield #-}

    yieldOr = yieldOr'
    {-# INLINE yieldOr #-}

    liftPipeMonad = lift

    addCleanup cleanup (Done r) = PipeM (cleanup True >> return (Done r))
    addCleanup cleanup (HaveOutput src close x) = HaveOutput
        (addCleanup cleanup src)
        (cleanup False >> close)
        x
    addCleanup cleanup (PipeM msrc) = PipeM (liftM (addCleanup cleanup) msrc)
    addCleanup cleanup (NeedInput p c) = NeedInput
        (addCleanup cleanup . p)
        (addCleanup cleanup . c)
    addCleanup cleanup (Leftover p i) = Leftover (addCleanup cleanup p) i

instance Monad m => IsPipe (SourceM o m) where
    type PipeInput (SourceM o m) = ()
    type PipeTerm (SourceM o m) = ()
    type PipeOutput (SourceM o m) = o
    type PipeMonad (SourceM o m) = m

    await = SourceM await
    {-# INLINE await #-}

    awaitE = SourceM awaitE
    {-# INLINE awaitE #-}

    leftover = SourceM . leftover
    {-# INLINE leftover #-}

    yield = SourceM . yield
    {-# INLINE yield #-}

    yieldOr a = SourceM . yieldOr a
    {-# INLINE yieldOr #-}

    liftPipeMonad = lift

    addCleanup c (SourceM p) = SourceM (addCleanup c p)

instance Monad m => IsPipe (ConduitM i o m) where
    type PipeInput (ConduitM i o m) = i
    type PipeTerm (ConduitM i o m) = ()
    type PipeOutput (ConduitM i o m) = o
    type PipeMonad (ConduitM i o m) = m

    await = ConduitM await
    {-# INLINE await #-}

    awaitE = ConduitM awaitE
    {-# INLINE awaitE #-}

    leftover = ConduitM . leftover
    {-# INLINE leftover #-}

    yield = ConduitM . yield
    {-# INLINE yield #-}

    yieldOr a = ConduitM . yieldOr a
    {-# INLINE yieldOr #-}

    liftPipeMonad = lift

    addCleanup c (ConduitM p) = ConduitM (addCleanup c p)

instance Monad m => IsPipe (Sink i m) where
    type PipeInput (Sink i m) = i
    type PipeTerm (Sink i m) = ()
    type PipeOutput (Sink i m) = Void
    type PipeMonad (Sink i m) = m

    await = Sink await
    {-# INLINE await #-}

    awaitE = Sink awaitE
    {-# INLINE awaitE #-}

    leftover = Sink . leftover
    {-# INLINE leftover #-}

    yield = Sink . yield
    {-# INLINE yield #-}

    yieldOr a = Sink . yieldOr a
    {-# INLINE yieldOr #-}

    liftPipeMonad = lift

    addCleanup c (Sink p) = Sink (addCleanup c p)

#define GOALL(C, T) instance C => IsPipe (T) where; type PipeInput (T) = PipeInput m; type PipeMonad (T) = PipeMonad m; type PipeTerm (T) = PipeTerm m; type PipeOutput (T) = PipeOutput m; await = lift await; awaitE = lift awaitE; leftover = lift . leftover; yield = lift . yield; yieldOr a = lift . yieldOr a; liftPipeMonad = lift . liftPipeMonad; addCleanup c r = liftWith (\run -> run $ addCleanup c r) >>= restoreT . return
#define GO(T) GOALL(IsPipe m, T m)
#define GOX(X, T) GOALL((IsPipe m, X), T m)
GO(IdentityT)
GO(ListT)
GO(MaybeT)
GOX(Error e, ErrorT e)
GO(ReaderT r)
GO(StateT s)
GOX(Monoid w, WriterT w)
GOX(Monoid w, RWST r w s)
GOX(Monoid w, Strict.RWST r w s)
GO(Strict.StateT s)
GOX(Monoid w, Strict.WriterT w)
GO(ResourceT)
#undef GO
#undef GOX
#undef GOALL

{-# RULES "await >>= maybe" forall x y. await >>= maybe x y = NeedInput y (const x) #-}
{-# RULES "awaitE >>= either" forall x y. awaitE >>= either x y = NeedInput y x #-}

-- | Wait for input forever, calling the given inner @Pipe@ for each piece of
-- new input. Returns the upstream result type.
--
-- Since 0.5.0
awaitForever :: (r ~ PipeTerm m, IsPipe m)
             => (PipeInput m -> m r')
             -> m r
awaitForever inner =
    self
  where
    self = awaitE >>= either return (\i -> inner i >> self)
{-# INLINE [1] awaitForever #-}


yield' :: Monad m => o -> Pipe i o u m ()
yield' = HaveOutput (Done ()) (return ())
{-# INLINE [1] yield' #-}

yieldOr' :: o -> m () -> Pipe i o u m ()
yieldOr' o f = HaveOutput (Done ()) f o
{-# INLINE [1] yieldOr' #-}

{-# RULES
    "yield o >> p" forall o (p :: Pipe i o u m r). yield' o >> p = HaveOutput p (return ()) o
  ; "mapM_ yield" mapM_ yield' = sourceList
  ; "yieldOr o c >> p" forall o c (p :: Pipe i o u m r). yieldOr' o c >> p = HaveOutput p c o
  #-}

{-# RULES "leftover l >> p" forall l (p :: Pipe l o u m r). leftover l >> p = Leftover p l #-}

class (IsPipe m, MonadResource (PipeMonad m), MonadIO m) => ResourcePipe m where
    -- | Perform some allocation and run an inner @Pipe@. Two guarantees are given
    -- about resource finalization:
    --
    -- 1. It will be /prompt/. The finalization will be run as early as possible.
    --
    -- 2. It is exception safe. Due to usage of @resourcet@, the finalization will
    --    be run in the event of any exceptions.
    --
    -- Since 0.5.0
    bracketP :: IO a -> (a -> IO ()) -> (a -> m r) -> m r

instance MonadResource m => ResourcePipe (Pipe i o u m) where
    bracketP alloc free inside =
        PipeM start
      where
        start = do
            (key, seed) <- allocate alloc free
            return $ addCleanup (const $ release key) (inside seed)

-- | The identity @Pipe@.
--
-- Since 0.5.0
idP :: Monad m => Pipe a a r m r
idP = NeedInput (HaveOutput idP (return ())) Done

-- | Compose a left and right pipe together into a complete pipe. The left pipe
-- will be automatically closed when the right pipe finishes.
--
-- Since 0.6.0
pipe :: Monad m => Pipe a b r0 m r1 -> Pipe b c r1 m r2 -> Pipe a c r0 m r2
pipe =
    pipe' (return ())
  where
    pipe' :: Monad m => m () -> Pipe a b r0 m r1 -> Pipe b c r1 m r2 -> Pipe a c r0 m r2
    pipe' final left right =
        case right of
            Done r2 -> PipeM (final >> return (Done r2))
            HaveOutput p c o -> HaveOutput (pipe' final left p) (c >> final) o
            PipeM mp -> PipeM (liftM (pipe' final left) mp)
            Leftover right' i -> pipe' final (HaveOutput left final i) right'
            NeedInput rp rc ->
                case left of
                    Done r1 -> pipe' (return ()) (Done r1) (rc r1)
                    HaveOutput left' final' o -> pipe' final' left' (rp o)
                    PipeM mp -> PipeM (liftM (\left' -> pipe' final left' right) mp)
                    NeedInput left' lc -> NeedInput
                        (\a -> pipe' final (left' a) right)
                        (\r0 -> pipe' final (lc r0) right)
                    Leftover left' i -> Leftover (pipe' final left' right) i

-- | Connect a @Source@ to a @Sink@ until the latter closes. Returns both the
-- most recent state of the @Source@ and the result of the @Sink@.
--
-- We use a @ResumableSource@ to keep track of the most recent finalizer
-- provided by the @Source@.
--
-- Since 0.5.0
connectResume :: Monad m
              => ResumableSource m o
              -> Sink o m r
              -> m (ResumableSource m o, r)
connectResume (ResumableSource left0 leftFinal0) (Sink sink0) =
    go leftFinal0 left0 sink0
  where
    go leftFinal left right =
        case right of
            Done r2 -> return (ResumableSource left leftFinal, r2)
            PipeM mp -> mp >>= go leftFinal left
            HaveOutput _ _ o -> absurd o
            Leftover p i -> go leftFinal (HaveOutput left leftFinal i) p
            NeedInput rp rc ->
                case left of
                    Leftover p () -> go leftFinal p right
                    HaveOutput left' leftFinal' o -> go leftFinal' left' (rp o)
                    NeedInput _ lc -> go leftFinal (lc ()) right
                    Done () -> go (return ()) (Done ()) (rc ())
                    PipeM mp -> mp >>= \left' -> go leftFinal left' right

-- | Run a pipeline until processing completes.
--
-- Since 0.5.0
runPipe :: Monad m => Pipe () Void () m r -> m r
runPipe (HaveOutput _ _ o) = absurd o
runPipe (NeedInput _ c) = runPipe (c ())
runPipe (Done r) = return r
runPipe (PipeM mp) = mp >>= runPipe
runPipe (Leftover p _) = runPipe p

-- | Transforms a @Pipe@ that provides leftovers to one which does not,
-- allowing it to be composed.
--
-- This function will provide any leftover values within this @Pipe@ to any
-- calls to @await@. If there are more leftover values than are demanded, the
-- remainder are discarded.
--
-- Since 0.5.0
injectLeftovers :: Monad m => Pipe i o u m r -> Pipe i o u m r
injectLeftovers =
    go []
  where
    go _ (Done r) = Done r
    go ls (HaveOutput p c o) = HaveOutput (go ls p) c o
    go ls (PipeM mp) = PipeM (liftM (go ls) mp)
    go ls (Leftover p l) = go (l:ls) p
    go (l:ls) (NeedInput p _) = go ls $ p l
    go [] (NeedInput p c) = NeedInput (go [] . p) (go [] . c)

class TransPipe t where
    -- | Transform the monad that a @Pipe@ lives in.
    --
    -- Note that the monad transforming function will be run multiple times,
    -- resulting in unintuitive behavior in some cases. For a fuller treatment,
    -- please see:
    --
    -- <https://github.com/snoyberg/conduit/wiki/Dealing-with-monad-transformers>
    --
    -- Since 0.4.0
    transPipe :: Monad m => (forall a. m a -> n a) -> t m r -> t n r

instance TransPipe (Pipe i o u) where
    transPipe f (HaveOutput p c o) = HaveOutput (transPipe f p) (f c) o
    transPipe f (NeedInput p c) = NeedInput (transPipe f . p) (transPipe f . c)
    transPipe _ (Done r) = Done r
    transPipe f (PipeM mp) =
        PipeM (f $ liftM (transPipe f) $ collapse mp)
      where
        -- Combine a series of monadic actions into a single action.  Since we
        -- throw away side effects between different actions, an arbitrary break
        -- between actions will lead to a violation of the monad transformer laws.
        -- Example available at:
        --
        -- http://hpaste.org/75520
        collapse mpipe = do
            pipe' <- mpipe
            case pipe' of
                PipeM mpipe' -> collapse mpipe'
                _ -> return pipe'
    transPipe f (Leftover p i) = Leftover (transPipe f p) i

instance TransPipe (SourceM o) where
    transPipe f (SourceM p) = SourceM (transPipe f p)
instance TransPipe (ConduitM i o) where
    transPipe f (ConduitM p) = ConduitM (transPipe f p)
instance TransPipe (Sink i) where
    transPipe f (Sink p) = Sink (transPipe f p)

-- | Apply a function to all the output values of a @Pipe@.
--
-- This mimics the behavior of `fmap` for a `Source` and `Conduit` in pre-0.4
-- days.
--
-- Since 0.4.1
mapOutput :: Monad m
          => (o1 -> o2)
          -> Pipe i o1 u m r
          -> Pipe i o2 u m r
mapOutput f (HaveOutput p c o) = HaveOutput (mapOutput f p) c (f o)
mapOutput f (NeedInput p c) = NeedInput (mapOutput f . p) (mapOutput f . c)
mapOutput _ (Done r) = Done r
mapOutput f (PipeM mp) = PipeM (liftM (mapOutput f) mp)
mapOutput f (Leftover p i) = Leftover (mapOutput f p) i

-- | Same as 'mapOutput', but use a function that returns @Maybe@ values.
--
-- Since 0.5.0
mapOutputMaybe :: Monad m
               => (o1 -> Maybe o2)
               -> Pipe i o1 u m r
               -> Pipe i o2 u m r
mapOutputMaybe f (HaveOutput p c o) = maybe id (\o' p' -> HaveOutput p' c o') (f o) (mapOutputMaybe f p)
mapOutputMaybe f (NeedInput p c) = NeedInput (mapOutputMaybe f . p) (mapOutputMaybe f . c)
mapOutputMaybe _ (Done r) = Done r
mapOutputMaybe f (PipeM mp) = PipeM (liftM (mapOutputMaybe f) mp)
mapOutputMaybe f (Leftover p i) = Leftover (mapOutputMaybe f p) i

-- | Apply a function to all the input values of a @Pipe@.
--
-- Since 0.5.0
mapInput :: Monad m
         => (i1 -> i2) -- ^ map initial input to new input
         -> (i2 -> Maybe i1) -- ^ map new leftovers to initial leftovers
         -> Pipe i2 o u m r
         -> Pipe i1 o u m r
mapInput f f' (HaveOutput p c o) = HaveOutput (mapInput f f' p) c o
mapInput f f' (NeedInput p c)    = NeedInput (mapInput f f' . p . f) (mapInput f f' . c)
mapInput _ _  (Done r)           = Done r
mapInput f f' (PipeM mp)         = PipeM (liftM (mapInput f f') mp)
mapInput f f' (Leftover p i)     = maybe id (flip Leftover) (f' i) $ mapInput f f' p

-- | Convert a list into a source.
--
-- Since 0.3.0
sourceList :: Monad m => [a] -> Pipe i a u m ()
sourceList =
    go
  where
    go [] = Done ()
    go (o:os) = HaveOutput (go os) (return ()) o
{-# INLINE [1] sourceList #-}

-- | The equivalent of @GHC.Exts.build@ for @Pipe@.
--
-- Since 0.4.2
build :: Monad m => (forall b. (o -> b -> b) -> b -> b) -> Pipe i o u m ()
build g = g (\o p -> HaveOutput p (return ()) o) (return ())

{-# RULES
    "sourceList/build" forall (f :: (forall b. (a -> b -> b) -> b -> b)). sourceList (GHC.Exts.build f) = build f
  #-}

fromPipe :: (Monad m, PipeOutput m ~ o, IsPipe m, i ~ PipeInput m, u ~ PipeTerm m)
         => Pipe i o u (PipeMonad m) r
         -> m r
fromPipe (Done r) = return r
fromPipe (HaveOutput p c o) = yieldOr o c >> fromPipe p
fromPipe (NeedInput p c) = awaitE >>= either (fromPipe . c) (fromPipe . p)
fromPipe (PipeM mp) = liftPipeMonad mp >>= fromPipe
fromPipe (Leftover p l) = leftover l >> fromPipe p
{-# RULES
    "fromPipe/Pipe" forall (p :: Pipe i o u m r). fromPipe p = p
  ; "fromPipe/SourceM" forall (p :: Pipe () o () m r). fromPipe p = SourceM p
  ; "fromPipe/ConduitM" forall (p :: Pipe i o () m r). fromPipe p = ConduitM p
  ; "fromPipe/Sink" forall (p :: Pipe i Void () m r). fromPipe p = Sink p
 #-}

class ToPipe m where
    type ToPipeInput m
    type ToPipeOutput m
    type ToPipeTerm m
    type ToPipeMonad m :: * -> *
    toPipe :: m r -> Pipe (ToPipeInput m) (ToPipeOutput m) (ToPipeTerm m) (ToPipeMonad m) r

instance Monad m => ToPipe (Pipe i o u m) where
    type ToPipeInput (Pipe i o u m) = i
    type ToPipeOutput (Pipe i o u m) = o
    type ToPipeTerm (Pipe i o u m) = u
    type ToPipeMonad (Pipe i o u m) = m
    toPipe = id

instance Monad m => ToPipe (Sink i m) where
    type ToPipeInput (Sink i m) = i
    type ToPipeOutput (Sink i m) = Void
    type ToPipeTerm (Sink i m) = ()
    type ToPipeMonad (Sink i m) = m
    toPipe =
        go . unSink
      where
        go (Done r) = Done r
        go (PipeM mp) = PipeM (liftM go mp)
        go (NeedInput p c) = NeedInput (go . p) (const $ go $ c ())
        go (HaveOutput _ _ o) = absurd o
        go (Leftover p l) = Leftover (go p) l

instance Monad m => ToPipe (SourceM o m) where
    type ToPipeInput (SourceM o m) = ()
    type ToPipeOutput (SourceM o m) = o
    type ToPipeTerm (SourceM o m) = ()
    type ToPipeMonad (SourceM o m) = m
    toPipe =
        go . unSourceM
      where
        go (Done r) = Done r
        go (PipeM mp) = PipeM (liftM go mp)
        go (NeedInput _ c) = go $ c ()
        go (HaveOutput p c o) = HaveOutput (go p) c o
        go (Leftover p ()) = Leftover (go p) ()

instance Monad m => ToPipe (ConduitM i o m) where
    type ToPipeInput (ConduitM i o m) = i
    type ToPipeOutput (ConduitM i o m) = o
    type ToPipeTerm (ConduitM i o m) = ()
    type ToPipeMonad (ConduitM i o m) = m

    toPipe =
        go . unConduitM
      where
        go (Done r) = Done r
        go (PipeM mp) = PipeM (liftM go mp)
        go (NeedInput p c) = NeedInput (go . p) (const $ go $ c ())
        go (HaveOutput p c o) = HaveOutput (go p) c o
        go (Leftover p l) = Leftover (go p) l

-- | Returns a tuple of the upstream and downstream results. Note that this
-- will force consumption of the entire input stream.
--
-- Since 0.5.0
withUpstream :: (u ~ PipeTerm m, IsPipe m)
             => m r
             -> m (u, r)
withUpstream down =
    down >>= go
  where
    go r =
        loop
      where
        loop = awaitE >>= either (\u -> return (u, r)) (\_ -> loop)

-- | Unwraps a @ResumableSource@ into a @Source@ and a finalizer.
--
-- A @ResumableSource@ represents a @Source@ which has already been run, and
-- therefore has a finalizer registered. As a result, if we want to turn it
-- into a regular @Source@, we need to ensure that the finalizer will be run
-- appropriately. By appropriately, I mean:
--
-- * If a new finalizer is registered, the old one should not be called.
-- * If the old one is called, it should not be called again.
--
-- This function returns both a @Source@ and a finalizer which ensures that the
-- above two conditions hold. Once you call that finalizer, the @Source@ is
-- invalidated and cannot be used.
--
-- Since 0.5.2
unwrapResumable :: MonadIO m => ResumableSource m o -> m (Source m o, m ())
unwrapResumable (ResumableSource src final) = do
    ref <- liftIO $ I.newIORef True
    let final' = do
            x <- liftIO $ I.readIORef ref
            when x final
    return (SourceM $ liftIO (I.writeIORef ref False) >> src, final')

instance MonadState s m => MonadState s (Pipe i o u m) where
  get = lift get
  put = lift . put
