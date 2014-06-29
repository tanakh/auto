{-# LANGUAGE DeriveFunctor #-}

module Control.Auto.Core (
  -- * Auto output
    Output(..)
  , onOutput
  -- * Auto type & accessors
  , Auto
  , loadAuto
  , saveAuto
  , stepAuto
  -- * Auto constructors
  -- ** Lifting functions
  , mkConst
  , mkConstM
  , mkFunc
  , mkFuncM
  -- ** from State transformers
  , mkState
  , mkStateM
  , mkState_
  , mkStateM_
  -- ** Arbitrary Autos
  , mkAuto
  , mkAutoM
  , mkAuto_
  , mkAutoM_
  ) where

import Control.Applicative
import Control.Arrow
import Control.Category
import Control.Monad
import Control.Monad.Fix
import Data.Binary
import Data.Monoid
import Prelude hiding      ((.), id)

data Output m a b = Output { outRes  :: !b
                           , outAuto :: !(Auto m a b)
                           } deriving Functor

onOutput :: (b -> b')
         -> (Auto m a b -> Auto m a' b')
         -> Output m a b -> Output m a' b'
onOutput fx fa (Output x a) = Output (fx x) (fa a)

data Auto m a b = Auto { loadAuto :: !(Get (Auto m a b))
                       , saveAuto :: !Put
                       , stepAuto :: !(a -> m (Output m a b))
                       }

mkAuto :: Monad m
       => Get (Auto m a b)
       -> Put
       -> (a -> Output m a b)
       -> Auto m a b
mkAuto l s f = mkAutoM l s (return . f)

mkAutoM :: Get (Auto m a b)
        -> Put
        -> (a -> m (Output m a b))
        -> Auto m a b
mkAutoM = Auto
{-# INLINE mkAutoM #-}

mkAuto_ :: Monad m
        => (a -> Output m a b)
        -> Auto m a b
mkAuto_ f = mkAutoM_ (return . f)

mkAutoM_ :: Monad m
         => (a -> m (Output m a b))
         -> Auto m a b
mkAutoM_ f = a
  where
    a = mkAutoM (pure a) (put ()) f

mkConst :: Monad m => b -> Auto m a b
mkConst = mkFunc . const

mkConstM :: Monad m => m b -> Auto m a b
mkConstM = mkFuncM . const

mkFunc :: Monad m
       => (a -> b)
       -> Auto m a b
mkFunc f = a
  where
    a = mkAuto_ $ \x -> Output (f x) a

mkFuncM :: Monad m
        => (a -> m b)
        -> Auto m a b
mkFuncM f = a
  where
    a = mkAutoM_ $ \x -> do
                      y <- f x
                      return (Output y a)

mkState :: (Binary s, Monad m)
        => (a -> s -> (b, s))
        -> s
        -> Auto m a b
mkState f s0 = mkAuto (mkState f <$> get)
                      (put s0)
                      $ \x -> let (y, s1) = f x s0
                              in  Output y (mkState f s1)

mkStateM :: (Binary s, Monad m)
         => (a -> s -> m (b, s))
         -> s
         -> Auto m a b
mkStateM f s0 = mkAutoM (mkStateM f <$> get)
                        (put s0)
                        $ \x -> do
                            (y, s1) <- f x s0
                            return (Output y (mkStateM f s1))

mkState_ :: Monad m
         => (a -> s -> (b, s))
         -> s
         -> Auto m a b
mkState_ f s0 = mkAuto_ $ \x -> let (y, s1) = f x s0
                                in  Output y (mkState_ f s1)

mkStateM_ :: Monad m
          => (a -> s -> m (b, s))
          -> s
          -> Auto m a b
mkStateM_ f s0 = mkAutoM_ $ \x -> do
                              (y, s1) <- f x s0
                              return (Output y (mkStateM_ f s1))

instance Monad m => Functor (Auto m a) where
    fmap f (Auto l s o) = Auto (fmap f <$> l)
                               s
                               $ \x -> liftM (fmap f) (o x)

instance Monad m => Applicative (Output m a) where
    pure x                      = Output x (pure x)
    Output fx ft <*> Output x t = Output (fx x) (ft <*> t)

instance Monad m => Applicative (Auto m a) where
    pure                         = mkConst
    Auto fl fs ft <*> Auto l s t = mkAutoM ((<*>) <$> fl <*> l)
                                           (fs *> s)
                                           $ \x -> liftM2 (<*>) (ft x) (t x)

instance Monad m => Category (Auto m) where
    id = mkFunc id
    Auto gl gs gt . Auto fl fs ft = mkAutoM ((.) <$> gl <*> fl)
                                            (gs *> fs)
                                            $ \x -> do
                                                Output y fa' <- ft x
                                                Output z ga' <- gt y
                                                return (Output z (ga' . fa'))

instance Monad m => Arrow (Auto m) where
    arr                = mkFunc
    first (Auto l s t) = mkAutoM (first <$> l)
                                 s
                                 $ \(x, y) -> do
                                     Output x' a' <- t x
                                     return (Output (x', y) (first a'))

instance Monad m => ArrowChoice (Auto m) where
    left (Auto l s t) = a
      where
        a = mkAutoM (left <$> l)
                    s
                    $ \x -> case x of
                        Left y  -> liftM (onOutput Left left) (t y)
                        Right y -> return (Output (Right y) a)

instance MonadFix m => ArrowLoop (Auto m) where
    loop (Auto l s t) = mkAutoM (loop <$> l)
                                s
                                $ \x -> liftM (onOutput fst loop)
                                      . mfix
                                      $ \(Output (_, d) _) -> t (x, d)

instance (Monad m, Monoid b) => Monoid (Auto m a b) where
    mempty  = pure mempty
    mappend = liftA2 mappend

instance (Monad m, Num b) => Num (Auto m a b) where
    (+)         = liftA2 (+)
    (*)         = liftA2 (*)
    (-)         = liftA2 (-)
    negate      = liftA negate
    abs         = liftA abs
    signum      = liftA signum
    fromInteger = pure . fromInteger

instance (Monad m, Fractional b) => Fractional (Auto m a b) where
    (/)          = liftA2 (/)
    recip        = liftA recip
    fromRational = pure . fromRational
