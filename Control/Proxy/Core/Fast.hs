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
    like 'runProxy' and 'observe'.

    Also, you really should not use the constructors anyway, let alone the
    concrete type and instead you should stick to the 'Proxy' type class API.
    This not only ensures that your code does not violate the monad transformer
    laws, but also guarantees that it works with the other proxy implementations
    and with any proxy transformers. -}

{-# LANGUAGE Trustworthy #-}
{- The rewrite RULES require the 'TrustWorthy' annotation.  Their proofs are
   pretty trivial since they are just inlining the definition of _bind.  GHC
   doesn't do this automatically because the @go@ helper function is recursive.
-}

module Control.Proxy.Core.Fast (
    -- * Types
    ProxyFast(..),

    -- * Run Sessions 
    -- $run
    runProxy,
    runProxyK,
    runPipe,

    -- * Safety
    observe
    ) where

import Control.Applicative (Applicative(pure, (<*>)))
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.MFunctor (MFunctor(hoist))
import Control.Proxy.Class
import Control.Proxy.Synonym (C)

{-| A 'ProxyFast' communicates with an upstream interface and a downstream
    interface.

    The type variables of @ProxyFast req_a' resp_a req_b' resp_b m r@ signify:

    * @req_a'@ - The request supplied to the upstream interface

    * @resp_a@ - The response provided by the upstream interface

    * @req_b'@ - The request supplied by the downstream interface

    * @resp_b@ - The response provided to the downstream interface

    * @m     @ - The base monad

    * @r     @ - The final return value -}
data ProxyFast a' a b' b m r
  = Request a' (a  -> ProxyFast a' a b' b m r )
  | Respond b  (b' -> ProxyFast a' a b' b m r )
  | M          (m    (ProxyFast a' a b' b m r))
  | Pure    r

instance (Monad m) => Functor (ProxyFast a' a b' b m) where
    fmap f p0 = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       r   -> Pure (f r)

instance (Monad m) => Applicative (ProxyFast a' a b' b m) where
    pure      = Pure
    pf <*> px = go pf where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       f   -> fmap f px

instance (Monad m) => Monad (ProxyFast a' a b' b m) where
    return = Pure
    (>>=)  = _bind

_bind
 :: (Monad m)
 => ProxyFast a' a b' b m r
 -> (r -> ProxyFast a' a b' b m r')
 -> ProxyFast a' a b' b m r'
p0 `_bind` f = go p0 where
    go p = case p of
        Request a' fa  -> Request a' (\a  -> go (fa  a))
        Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
        M          m   -> M (m >>= \p' -> return (go p'))
        Pure       r   -> f r

{-# RULES
    "_bind (Request a' k) f" forall a' k f .
        _bind (Request a' k) f = Request a' (\a  -> _bind (k a)  f);
    "_bind (Respond b  k) f" forall b  k f .
        _bind (Respond b  k) f = Respond b  (\b' -> _bind (k b') f);
    "_bind (M          m) f" forall m    f .
        _bind (M          m) f = M (m >>= \p -> return (_bind p f));
    "_bind (Pure    r   ) f" forall r    f .
        _bind (Pure       r) f = f r;
  #-}

instance MonadP ProxyFast where
    return_P = Pure
    (?>=)   = _bind

-- | Only satisfies laws modulo 'observe'
instance MonadTrans (ProxyFast a' a b' b) where
    lift m = M (m >>= \r -> return (Pure r))

instance MonadTransP ProxyFast where
    lift_P = lift

instance (MonadIO m) => MonadIO (ProxyFast a' a b' b m) where
    liftIO m = M (liftIO (m >>= \r -> return (Pure r)))
 -- liftIO = M . liftIO . liftM Pure

instance MonadIOP ProxyFast where
    liftIO_P = liftIO

instance Proxy ProxyFast where
    fb' ->> p = case p of
        Request b' fb  -> fb' b' >>~ fb
        Respond c  fc' -> Respond c (\c' -> fb' ->> fc' c')
        M          m   -> M (m >>= \p' -> return (fb' ->> p'))
        Pure       r   -> Pure r

    p >>~ fb = case p of
        Request a' fa  -> Request a' (\a -> fa a >>~ fb)
        Respond b  fb' -> fb' ->> fb b
        M          m   -> M (m >>= \p' -> return (p' >>~ fb))
        Pure       r   -> Pure r

    request = \a' -> Request a' Pure
    respond = \b  -> Respond b  Pure

instance Interact ProxyFast where
    fb' >\\ p0 = go p0 where
        go p = case p of
            Request b' fb  -> fb' b' >>= \b -> go (fb b)
            Respond x  fx' -> Respond x (\x' -> go (fx' x'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       a   -> Pure a

    p0 //> fb = go p0 where
        go p = case p of
            Request x' fx  -> Request x' (\x -> go (fx x))
            Respond b  fb' -> fb b >>= \b' -> go (fb' b')
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       a   -> Pure a

instance MFunctor (ProxyFast a' a b' b) where
    hoist nat p0 = go (observe p0) where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (nat (m >>= \p' -> return (go p')))
            Pure       r   -> Pure r

instance MFunctorP ProxyFast where
    hoist_P = hoist

{- $run
    The following commands run self-sufficient proxies, converting them back to
    the base monad.

    These are the only functions specific to the 'ProxyFast' type.  Everything
    else programs generically over the 'Proxy' type class.

    Use 'runProxyK' if you are running proxies nested within proxies.  It
    provides a Kleisli arrow as its result that you can pass to another
    'runProxy' / 'runProxyK' command. -}

{-| Run a self-sufficient 'ProxyFast' Kleisli arrow, converting it back to the
    base monad -}
runProxy :: (Monad m) => (() -> ProxyFast a' () () b m r) -> m r
runProxy k = go (k ()) where
    go p = case p of
        Request _ fa  -> go (fa  ())
        Respond _ fb' -> go (fb' ())
        M         m   -> m >>= go
        Pure      r   -> return r

{-| Run a self-sufficient 'ProxyFast' Kleisli arrow, converting it back to a
    Kleisli arrow in the base monad -}
runProxyK :: (Monad m) => (() -> ProxyFast a' () () b m r) -> (() -> m r)
runProxyK p = \() -> runProxy p

-- | Run the 'Pipe' monad transformer, converting it back to the base monad
runPipe :: (Monad m) => ProxyFast a' () () b m r -> m r
runPipe p = runProxy (\_ -> p)

{-| The monad transformer laws are correct when viewed through the 'observe'
    function:

> observe (lift (return r)) = observe (return r)
>
> observe (lift (m >>= f)) = observe (lift m >>= lift . f)

    This correctness comes at a moderate cost to performance, so use this
    function sparingly or else you would be better off using
    "Control.Proxy.Core.Correct".

    You do not need to use this function if you use the safe API exported from
    "Control.Proxy", which does not export any functions or constructors that
    can violate the monad transformer laws.
-}
observe :: (Monad m) => ProxyFast a' a b' b m r -> ProxyFast a' a b' b m r
observe p = M (go p) where
    go p = case p of
        M          m'  -> m' >>= go
        Pure       r   -> return (Pure r)
        Request a' fa  -> return (Request a' (\a  -> observe (fa  a )))
        Respond b  fb' -> return (Respond b  (\b' -> observe (fb' b')))
