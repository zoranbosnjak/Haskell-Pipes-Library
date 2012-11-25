{-| This is an internal module, meaning that it is unsafe to import unless you
    understand the risks.

    This module provides the fast proxy implementation, which achieves its speed
    by weakening the monad transformer laws.  These laws do not hold if you can
    pattern match on the constructors, as the following counter-example
    illustrates:

> lift . return = M . return . Pure
>
> return = Pure
>
> lift . return /= return

    These laws only hold when viewed through certain safe observation functions,
    like 'runProxy', which cannot distinguish the above two alternatives:

> runProxy (lift (return r)) = runProxy (return r)

    Also, you really should not use the constructors anyway and instead you
    should stick to the 'ProxyP' API.  This not only ensures that your code does
    not violate the monad transformer laws, but also guarantees that it works
    with the other 'Proxy' implementation and with any proxy transformers. -}

module Control.Proxy.Core.Fast (
    -- * Types
    Proxy(..),

    -- * Run Sessions 
    -- $run
    runProxy,
    runProxyK,
    runPipe,
    ) where

import Control.Applicative (Applicative(pure, (<*>)))
-- import Control.Monad (ap, forever, liftM, (>=>))
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.MFunctor (MFunctor(mapT))
import Control.Proxy.Class
import Data.Closed (C)

{-| A 'Proxy' communicates with an upstream interface and a downstream
    interface.

    The type variables of @Proxy req_a resp_a req_b resp_b m r@ signify:

    * @req_a @ - The request supplied to the upstream interface

    * @resp_a@ - The response provided by the upstream interface

    * @req_b @ - The request supplied by the downstream interface

    * @resp_b@ - The response provided to the downstream interface

    * @m     @ - The base monad

    * @r     @ - The final return value -}
data Proxy a' a b' b m r
  = Request a' (a  -> Proxy a' a b' b m r )
  | Respond b  (b' -> Proxy a' a b' b m r )
  | M          (m    (Proxy a' a b' b m r))
  | Pure    r

instance (Monad m) => Functor (Proxy a' a b' b m) where
    fmap f p0 = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       r   -> Pure (f r)

instance (Monad m) => Applicative (Proxy a' a b' b m) where
    pure      = Pure
    pf <*> px = go pf where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       f   -> fmap f px

instance (Monad m) => Monad (Proxy a' a b' b m) where
    return = Pure
    (>>=)  = _bind

_bind
 :: (Monad m)
 => Proxy a' a b' b m r -> (r -> Proxy a' a b' b m r') -> Proxy a' a b' b m r'
p0 `_bind` f = go p0 where
    go p = case p of
        Request a' fa  -> Request a' (\a  -> go (fa  a))
        Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
        M          m   -> M (m >>= \p' -> return (go p'))
        Pure       r   -> f r

instance MonadTrans (Proxy a' a b' b) where
    lift = _lift

_lift :: (Monad m) => m r -> Proxy a' a b' b m r
_lift m = M (m >>= \r -> return (Pure r))
-- _lift = M . liftM Pure

{- These never fire, for some reason, but keep them until I figure out how to
   get them to work. -}
{-# RULES
    "_lift m ?>= f" forall m f .
        _bind (_lift m) f = M (m >>= \r -> return (f r))
  #-}

instance (MonadIO m) => MonadIO (Proxy a' a b' b m) where
    liftIO m = M (liftIO (m >>= \r -> return (Pure r)))
 -- liftIO = M . liftIO . liftM Pure

instance MonadIOP Proxy where
    liftIO_P = liftIO

instance ProxyP Proxy where
    idT = \a' -> Request a' (\a -> Respond a idT)
    k1 <-< k2_0 = \c' -> k1 c' |-< k2_0 where
        p1 |-< k2 = case p1 of
            Request b' fb  -> fb <-| k2 b'
            Respond c  fc' -> Respond c (\c' -> fc' c' |-< k2)
            M          m   -> M (m >>= \p1' -> return (p1' |-< k2))
            Pure       r   -> Pure r
        fb <-| p2 = case p2 of
            Request a' fa  -> Request a' (\a -> fb <-| fa a) 
            Respond b  fb' -> fb b |-< fb'
            M          m   -> M (m >>= \p2' -> return (fb <-| p2'))
            Pure       r   -> Pure r

    request a' = Request a' Pure
    respond b  = Respond b  Pure

    return_P = return
    (?>=)   = _bind

    lift_P = _lift

{-# RULES
    "_bind (Request a' Pure) f" forall a' f .
        _bind (Request a' Pure) f = Request a' f;
    "_bind (Respond b  Pure) f" forall b  f .
        _bind (Respond b  Pure) f = Respond b  f
  #-}

instance InteractP Proxy where
    k1 /</ k2 = \a' -> go (k1 a') where
        go p = case p of
            Request b' fb  -> k2 b' >>= \b -> go (fb b)
            Respond x  fx' -> Respond x (\x' -> go (fx' x'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       a   -> Pure a
    k1 \<\ k2 = \a' -> go (k2 a') where
        go p = case p of
            Request x' fx  -> Request x' (\x -> go (fx x))
            Respond b  fb' -> k1 b >>= \b' -> go (fb' b')
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       a   -> Pure a

instance MFunctor (Proxy a' a b' b) where
    mapT nat p0 = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (nat (m >>= \p' -> return (go p')))
            Pure       r   -> Pure r

instance MFunctorP Proxy where
    mapT_P = mapT

{- $run
    The following commands run self-sufficient proxies, converting them back to
    the base monad.

    These are the only functions specific to the 'Proxy' type.  Everything else
    programs generically over the 'ProxyP' type class.

    Use 'runProxyK' if you are running proxies nested within proxies.  It
    provides a Kleisli arrow as its result that you can pass to another
    'runProxy' / 'runProxyK' command. -}

{-| Run a self-sufficient 'Proxy' Kleisli arrow, converting it back to the base
    monad -}
runProxy :: (Monad m) => (() -> Proxy a' () () b m r) -> m r
runProxy k = go (k ()) where
    go p = case p of
        Request _ fa  -> go (fa  ())
        Respond _ fb' -> go (fb' ())
        M         m   -> m >>= go
        Pure      r   -> return r

{-| Run a self-sufficient 'Proxy' Kleisli arrow, converting it back to a Kleisli
    arrow in the base monad -}
runProxyK :: (Monad m) => (() -> Proxy a' () () b m r) -> (() -> m r)
runProxyK p = \() -> runProxy p

-- | Run the 'Pipe' monad transformer, converting it back to the base monad
runPipe :: (Monad m) => Proxy a' () () b m r -> m r
runPipe p = runProxy (\_ -> p)
