{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE EmptyCase                  #-}
{-# LANGUAGE EmptyDataDeriving          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE QuantifiedConstraints      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ViewPatterns               #-}

-- |
-- Module      : Data.HBifunctor.Associative
-- Copyright   : (c) Justin Le 2019
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- This module provides tools for working with binary functor combinators
-- that represent interpretable schemas.
--
-- These are types @'HBifunctor' t@ that take two functors @f@ and @g@ and returns a new
-- functor @t f g@, that "mixes together" @f@ and @g@ in some way.
--
-- The high-level usage of this is
--
-- @
-- 'biretract' :: t f f ~> f
-- @
--
-- which lets you fully "mix" together the two input functors.
--
-- This class also associates each 'HBifunctor' with its "semigroup functor
-- combinator", so we can "squish together" repeated applications of @t@.
--
-- That is, an @'NonEmptyBy' t f a@ is either:
--
-- *   @f a@
-- *   @t f f a@
-- *   @t f (t f f) a@
-- *   @t f (t f (t f f)) a@
-- *   .. etc.
--
-- which means we can have "list-like" schemas that represent multiple
-- copies of @f@.
--
-- See "Data.HBifunctor.Tensor" for a version that also provides an analogy
-- to 'inject', and a more flexible "squished" combinator
-- 'Data.HBifunctor.Tensor.MF' that has an "empty" element.
module Data.HBifunctor.Associative (
  -- * 'Associative'
    Associative(..)
  , assoc
  , disassoc
  -- * 'Semigroupoidal'
  , SemigroupIn(..)
  -- , CS
  , matchingNEB
  -- ** Utility
  , biget
  , bicollect
  , (!*!)
  , (!$!)
  ) where

import           Control.Applicative
import           Control.Applicative.ListF
import           Control.Applicative.Step
import           Control.Monad.Freer.Church
import           Control.Monad.Trans.Compose
import           Control.Monad.Trans.Identity
import           Control.Natural
import           Control.Natural.IsoF
import           Data.Bifunctor.Joker
import           Data.Coerce
import           Data.Data
import           Data.Foldable
import           Data.Functor.Apply.Free
import           Data.Functor.Bind
import           Data.Functor.Day             (Day(..))
import           Data.Functor.Identity
import           Data.Functor.Plus
import           Data.Functor.Product
import           Data.Functor.Sum
import           Data.Functor.These
import           Data.HBifunctor
import           Data.HFunctor
import           Data.HFunctor.Internal
import           Data.HFunctor.Interpret
import           Data.Kind
import           Data.List.NonEmpty           (NonEmpty(..))
import           GHC.Generics hiding          (C)
import qualified Data.Functor.Day             as D
import qualified Data.Map.NonEmpty            as NEM

-- | An 'HBifunctor' where it doesn't matter which binds first is
-- 'Associative'.  Knowing this gives us a lot of power to rearrange the
-- internals of our 'HFunctor' at will.
--
-- For example, for the functor product:
--
-- @
-- data (f ':*:' g) a = f a :*: g a
-- @
--
-- We know that @f :*: (g :*: h)@ is the same as @(f :*: g) :*: h@.
class (HBifunctor t, Inject (NonEmptyBy t)) => Associative t where
    -- | The "semigroup functor combinator" generated by @t@.
    --
    -- A value of type @NonEmptyBy t f a@ is /equivalent/ to one of:
    --
    -- *  @f a@
    -- *  @t f f a@
    -- *  @t f (t f f) a@
    -- *  @t f (t f (t f f)) a@
    -- *  @t f (t f (t f (t f f))) a@
    -- *  .. etc
    --
    -- For example, for ':*:', we have 'NonEmptyF'.  This is because:
    --
    -- @
    -- x             ~ 'NonEmptyF' (x ':|' [])      ~ 'inject' x
    -- x ':*:' y       ~ NonEmptyF (x :| [y])     ~ 'toNEB' (x :*: y)
    -- x :*: y :*: z ~ NonEmptyF (x :| [y,z])
    -- -- etc.
    -- @
    --
    -- You can create an "singleton" one with 'inject', or else one from
    -- a single @t f f@ with 'toNEB'.
    type NonEmptyBy t :: (Type -> Type) -> Type -> Type

    -- | The isomorphism between @t f (t g h) a@ and @t (t f g) h a@.  To
    -- use this isomorphism, see 'assoc' and 'disassoc'.
    associating
        :: (Functor f, Functor g, Functor h)
        => t f (t g h) <~> t (t f g) h

    -- | If a @'NonEmptyBy' t f@ represents multiple applications of @t f@ to
    -- itself, then we can also "append" two @'NonEmptyBy' t f@s applied to
    -- themselves into one giant @'NonEmptyBy' t f@ containing all of the @t f@s.
    appendNEB :: t (NonEmptyBy t f) (NonEmptyBy t f) ~> NonEmptyBy t f
    matchNEB  :: Functor f => NonEmptyBy t f ~> f :+: t f (NonEmptyBy t f)

    -- | Prepend an application of @t f@ to the front of a @'NonEmptyBy' t f@.
    consNEB :: t f (NonEmptyBy t f) ~> NonEmptyBy t f
    consNEB = appendNEB . hleft inject

    -- | Embed a direct application of @f@ to itself into a @'NonEmptyBy' t f@.
    toNEB :: t f f ~> NonEmptyBy t f
    toNEB = consNEB . hright inject

    {-# MINIMAL associating, appendNEB, matchNEB #-}

-- | Reassociate an application of @t@.
assoc
    :: (Associative t, Functor f, Functor g, Functor h)
    => t f (t g h)
    ~> t (t f g) h
assoc = viewF associating

-- | Reassociate an application of @t@.
disassoc
    :: (Associative t, Functor f, Functor g, Functor h)
    => t (t f g) h
    ~> t f (t g h)
disassoc = reviewF associating

class Associative t => SemigroupIn t f where
    -- | The 'HBifunctor' analogy of 'retract'. It retracts /both/ @f@s
    -- into a single @f@, effectively fully mixing them together.
    --
    -- This function makes @f@ a semigroup in the category of endofunctors
    -- with respect to tensor @t@.
    biretract :: t f f ~> f

    default biretract :: Interpret (NonEmptyBy t) f => t f f ~> f
    biretract = retract . consNEB . hright inject

    -- | The 'HBifunctor' analogy of 'interpret'.  It takes two
    -- interpreting functions, and mixes them together into a target
    -- functor @h@.
    binterpret
        :: g ~> f
        -> h ~> f
        -> t g h ~> f

    default binterpret :: Interpret (NonEmptyBy t) f => (g ~> f) -> (h ~> f) -> t g h ~> f
    binterpret f g = retract . toNEB . hbimap f g

---- | For some @t@s, you can represent the act of applying a functor @f@ to
---- @t@ many times, as a single type.  That is, there is some type @'NonEmptyBy'
---- t f@ that is equivalent to one of:
----
---- *  @f a@                             -- 1 time
---- *  @t f f a@                         -- 2 times
---- *  @t f (t f f) a@                   -- 3 times
---- *  @t f (t f (t f f)) a@             -- 4 times
---- *  @t f (t f (t f (t f f))) a@       -- 5 times
---- *  .. etc
----
---- This typeclass associates each @t@ with its "induced semigroupoidal
---- functor combinator" @'NonEmptyBy' t@.
----
---- This is useful because sometimes you might want to describe a type that
---- can be @t f f@, @t f (t f f)@, @t f (t f (t f f))@, etc.; "f applied to
---- itself", with at least one @f@.  This typeclass lets you use a type like
---- 'NonEmptyF' in terms of repeated applications of ':*:', or 'Ap1' in
---- terms of repeated applications of 'Day', or 'Free1' in terms of repeated
---- applications of 'Comp', etc.
----
---- For example, @f ':*:' f@ can be interpreted as "a free selection of two
---- @f@s", allowing you to specify "I have to @f@s that I can use".  If you
---- want to specify "I want 1, 2, or many different @f@s that I can use",
---- you can use @'NonEmptyF' f@.
----
---- At the high level, the main way to /use/ a 'Semigroupoidal' is with
---- 'biretract' and 'binterpret':
----
---- @
---- 'biretract' :: t f f '~>' f
---- 'binterpret' :: (f ~> h) -> (g ~> h) -> t f g ~> h
---- @
----
---- which are like the 'HBifunctor' versions of 'retract' and 'interpret':
---- they fully "mix" together the two inputs of @t@.
----
---- Also useful is:
----
---- @
---- 'toNEB' :: t f f a -> NonEmptyBy t f a
---- @
----
---- Which converts a @t@ into its aggregate type 'NonEmptyBy'.
----
---- In reality, most 'Semigroupoidal' instances are also
---- 'Data.HBifunctor.Tensor.Monoidal' instances, so you can think of the
---- separation as mostly to help organize functionality.  However, there are
---- two non-monoidal semigroupoidal instances of note: 'LeftF' and 'RightF',
---- which are higher order analogues of the 'Data.Semigroup.First' and
---- 'Data.Semigroup.Last' semigroups, roughly.
--class (Associative t, Interpret (NonEmptyBy t)) => Semigroupoidal t where
--    -- | The "semigroup functor combinator" generated by @t@.
--    --
--    -- A value of type @NonEmptyBy t f a@ is /equivalent/ to one of:
--    --
--    -- *  @f a@
--    -- *  @t f f a@
--    -- *  @t f (t f f) a@
--    -- *  @t f (t f (t f f)) a@
--    -- *  @t f (t f (t f (t f f))) a@
--    -- *  .. etc
--    --
--    -- For example, for ':*:', we have 'NonEmptyF'.  This is because:
--    --
--    -- @
--    -- x             ~ 'NonEmptyF' (x ':|' [])      ~ 'inject' x
--    -- x ':*:' y       ~ NonEmptyF (x :| [y])     ~ 'toNEB' (x :*: y)
--    -- x :*: y :*: z ~ NonEmptyF (x :| [y,z])
--    -- -- etc.
--    -- @
--    --
--    -- You can create an "singleton" one with 'inject', or else one from
--    -- a single @t f f@ with 'toNEB'.
--    type NonEmptyBy t :: (Type -> Type) -> Type -> Type

--    -- | The 'HBifunctor' analogy of 'retract'. It retracts /both/ @f@s
--    -- into a single @f@, effectively fully mixing them together.
--    --
--    -- This function makes @f@ a semigroup in the category of endofunctors
--    -- with respect to tensor @t@.
--    biretract :: CS t f => t f f ~> f
--    biretract = retract . toNEB

--    -- | The 'HBifunctor' analogy of 'interpret'.  It takes two
--    -- interpreting functions, and mixes them together into a target
--    -- functor @h@.
--    binterpret
--        :: CS t h
--        => f ~> h
--        -> g ~> h
--        -> t f g ~> h
--    binterpret f g = retract . toNEB . hbimap f g

--    {-# MINIMAL appendNEB, matchNEB #-}

------ | Convenient alias for the constraint required for 'biretract',
------ 'binterpret', etc.
------
------ It's usually a constraint on the target/result context of interpretation
------ that allows you to "exit" or "run" a @'Semigroupoidal' t@.
----type CS t = C (NonEmptyBy t)

-- | An @'NonEmptyBy' t f@ represents the successive application of @t@ to @f@,
-- over and over again.   So, that means that an @'NonEmptyBy' t f@ must either be
-- a single @f@, or an @t f (NonEmptyBy t f)@.
--
-- 'matchingNEB' states that these two are isomorphic.  Use 'matchNEB' and
-- @'inject' '!*!' 'consNEB'@ to convert between one and the other.
matchingNEB :: (Associative t, Functor f) => NonEmptyBy t f <~> f :+: t f (NonEmptyBy t f)
matchingNEB = isoF matchNEB (inject !*! consNEB)

-- | Useful wrapper over 'binterpret' to allow you to directly extract
-- a value @b@ out of the @t f a@, if you can convert @f x@ into @b@.
--
-- Note that depending on the constraints on the interpretation of @t@, you
-- may have extra constraints on @b@.
--
-- *    If @'C' ('NonEmptyBy' t)@ is 'Data.Constraint.Trivial.Unconstrained', there
--      are no constraints on @b@
-- *    If @'C' ('NonEmptyBy' t)@ is 'Apply', @b@ needs to be an instance of 'Semigroup'
-- *    If @'C' ('NonEmptyBy' t)@ is 'Applicative', @b@ needs to be an instance of 'Monoid'
--
-- For some constraints (like 'Monad'), this will not be usable.
--
-- @
-- -- Return the length of either the list, or the Map, depending on which
-- --   one s in the '+'
-- 'biget' 'length' length
--     :: ([] :+: 'Data.Map.Map' 'Int') 'Char'
--     -> Int
--
-- -- Return the length of both the list and the map, added together
-- 'biget' ('Data.Monoid.Sum' . length) (Sum . length)
--     :: 'Day' [] (Map Int) Char
--     -> Sum Int
-- @
biget
    :: SemigroupIn t (Const b)
    => (forall x. f x -> b)
    -> (forall x. g x -> b)
    -> t f g a
    -> b
biget f g = getConst . binterpret (Const . f) (Const . g)

-- | Infix alias for 'biget'
--
-- @
-- -- Return the length of either the list, or the Map, depending on which
-- --   one s in the '+'
-- 'length' '!$!' length
--     :: ([] :+: 'Data.Map.Map' 'Int') 'Char'
--     -> Int
--
-- -- Return the length of both the list and the map, added together
-- 'Data.Monoid.Sum' . length !$! Sum . length
--     :: 'Day' [] (Map Int) Char
--     -> Sum Int
-- @
(!$!)
    :: SemigroupIn t (Const b)
    => (forall x. f x -> b)
    -> (forall x. g x -> b)
    -> t f g a
    -> b
(!$!) = biget
infixr 5 !$!

-- | Infix alias for 'binterpret'
(!*!)
    :: SemigroupIn t h
    => (f ~> h)
    -> (g ~> h)
    -> t f g
    ~> h
(!*!) = binterpret
infixr 5 !*!

-- | Useful wrapper over 'biget' to allow you to collect a @b@ from all
-- instances of @f@ and @g@ inside a @t f g a@.
--
-- This will work if @'C' t@ is 'Data.Constraint.Trivial.Unconstrained',
-- 'Apply', or 'Applicative'.
bicollect
    :: SemigroupIn t (Const [b])
    => (forall x. f x -> b)
    -> (forall x. g x -> b)
    -> t f g a
    -> [b]
bicollect f g = biget ((:[]) . f) ((:[]) . g)

instance Associative (:*:) where
    type NonEmptyBy (:*:) = NonEmptyF

    associating = isoF to_ from_
      where
        to_   (x :*: (y :*: z)) = (x :*: y) :*: z
        from_ ((x :*: y) :*: z) = x :*: (y :*: z)

    appendNEB (NonEmptyF xs :*: NonEmptyF ys) = NonEmptyF (xs <> ys)
    matchNEB x = case ys of
        L1 ~Proxy -> L1 y
        R1 zs     -> R1 $ y :*: zs
      where
        y :*: ys = fromListF `hright` nonEmptyProd x

    consNEB (x :*: NonEmptyF xs) = NonEmptyF $ x :| toList xs
    toNEB   (x :*: y           ) = NonEmptyF $ x :| [y]

instance Alt f => SemigroupIn (:*:) f where
    biretract (x :*: y) = x <!> y
    binterpret f g (x :*: y) = f x <!> g y

instance Associative Product where
    type NonEmptyBy Product = NonEmptyF

    associating = isoF to_ from_
      where
        to_   (Pair x (Pair y z)) = Pair (Pair x y) z
        from_ (Pair (Pair x y) z) = Pair x (Pair y z)

    appendNEB (NonEmptyF xs `Pair` NonEmptyF ys) = NonEmptyF (xs <> ys)
    matchNEB x = case ys of
        L1 ~Proxy -> L1 y
        R1 zs     -> R1 $ Pair y zs
      where
        y :*: ys = fromListF `hright` nonEmptyProd x

    consNEB (x `Pair` NonEmptyF xs) = NonEmptyF $ x :| toList xs
    toNEB   (x `Pair` y           ) = NonEmptyF $ x :| [y]

instance Alt f => SemigroupIn Product f where
    biretract (Pair x y) = x <!> y
    binterpret f g (Pair x y) = f x <!> g y

instance Associative Day where
    type NonEmptyBy Day = Ap1
    associating = isoF D.assoc D.disassoc

    appendNEB (Day x y z) = z <$> x <.> y
    matchNEB a = case fromAp `hright` ap1Day a of
      Day x y z -> case y of
        L1 (Identity y') -> L1 $ (`z` y') <$> x
        R1 ys            -> R1 $ Day x ys z

    consNEB (Day x y z) = Ap1 x $ flip z <$> toAp y
    toNEB   (Day x y z) = z <$> inject x <.> inject y

instance Apply f => SemigroupIn Day f where
    biretract (Day x y z) = z <$> x <.> y
    binterpret f g (Day x y z) = z <$> f x <.> g y

instance Associative (:+:) where
    type NonEmptyBy (:+:) = Step

    associating = isoF to_ from_
      where
        to_ = \case
          L1 x      -> L1 (L1 x)
          R1 (L1 y) -> L1 (R1 y)
          R1 (R1 z) -> R1 z
        from_ = \case
          L1 (L1 x) -> L1 x
          L1 (R1 y) -> R1 (L1 y)
          R1 z      -> R1 (R1 z)

    appendNEB = \case
      L1 (Step i x) -> Step (i + 1) x
      R1 (Step i y) -> Step (i + 2) y
    matchNEB = hright stepDown . stepDown

    consNEB = stepUp . R1 . stepUp
    toNEB = \case
      L1 x -> Step 1 x
      R1 y -> Step 2 y

instance SemigroupIn (:+:) f where
    biretract = \case
      L1 x -> x
      R1 y -> y
    binterpret f g = \case
      L1 x -> f x
      R1 y -> g y

instance Associative Sum where
    type NonEmptyBy Sum = Step
    associating = isoF to_ from_
      where
        to_ = \case
          InL x       -> InL (InL x)
          InR (InL y) -> InL (InR y)
          InR (InR z) -> InR z
        from_ = \case
          InL (InL x) -> InL x
          InL (InR y) -> InR (InL y)
          InR z       -> InR (InR z)

    appendNEB = \case
      InL (Step i x) -> Step (i + 1) x
      InR (Step i y) -> Step (i + 2) y
    matchNEB = hright (viewF sumSum . stepDown) . stepDown

    consNEB = stepUp . R1 . stepUp . reviewF sumSum
    toNEB = \case
      InL x -> Step 1 x
      InR y -> Step 2 y

instance SemigroupIn Sum f where
    biretract = \case
      InR x -> x
      InL y -> y
    binterpret f g = \case
      InL x -> f x
      InR y -> g y

-- | Ideally here 'NonEmptyBy' would be equivalent to 'Data.HBifunctor.Tensor.MF',
-- just like for ':+:'. This should be possible if we can write
-- a bijection.  This bijection should be possible in theory --- but it has
-- not yet been implemented.
instance Associative These1 where
    type NonEmptyBy These1 = ComposeT Flagged Steps
    associating = isoF to_ from_
      where
        to_ = \case
          This1  x              -> This1  (This1  x  )
          That1    (This1  y  ) -> This1  (That1    y)
          That1    (That1    z) -> That1               z
          That1    (These1 y z) -> These1 (That1    y) z
          These1 x (This1  y  ) -> This1  (These1 x y)
          These1 x (That1    z) -> These1 (This1  x  ) z
          These1 x (These1 y z) -> These1 (These1 x y) z
        from_ = \case
          This1  (This1  x  )   -> This1  x
          This1  (That1    y)   -> That1    (This1  y  )
          This1  (These1 x y)   -> These1 x (This1  y  )
          That1               z -> That1    (That1    z)
          These1 (This1  x  ) z -> These1 x (That1    z)
          These1 (That1    y) z -> That1    (These1 y z)
          These1 (These1 x y) z -> These1 x (These1 y z)

    appendNEB s = ComposeT $ case s of
        This1  (ComposeT (Flagged _ q))                       ->
          Flagged True q
        That1                           (ComposeT (Flagged b q)) ->
          Flagged b        (stepsUp (That1 q))
        These1 (ComposeT (Flagged a q)) (ComposeT (Flagged b r)) ->
          Flagged (a || b) (q <> r)
    matchNEB (ComposeT (Flagged isImpure q)) = case stepsDown q of
      This1  x
        | isImpure  -> R1 $ This1 x
        | otherwise -> L1 x
      That1    y    -> R1 . That1 . ComposeT $ Flagged isImpure y
      These1 x y    -> R1 . These1 x .  ComposeT $ Flagged isImpure y

    consNEB s = ComposeT $ case s of
      This1  x                          -> Flagged True (inject x)
      That1    (ComposeT (Flagged b y)) -> Flagged b    (stepsUp (That1    y))
      These1 x (ComposeT (Flagged b y)) -> Flagged b    (stepsUp (These1 x y))
    toNEB  s = ComposeT $ case s of
      This1  x   -> Flagged True  . Steps $ NEM.singleton 0 x
      That1    y -> Flagged False . Steps $ NEM.singleton 1 y
      These1 x y -> Flagged False . Steps $ NEM.fromDistinctAscList $ (0, x) :| [(1, y)]

instance Alt f => SemigroupIn These1 f where
    biretract = \case
      This1  x   -> x
      That1    y -> y
      These1 x y -> x <!> y
    binterpret f g = \case
      This1  x   -> f x
      That1    y -> g y
      These1 x y -> f x <!> g y

instance Associative Void3 where
    type NonEmptyBy Void3 = IdentityT
    associating = isoF coerce coerce

    appendNEB = \case {}
    matchNEB  = L1 . runIdentityT

    consNEB = \case {}
    toNEB   = \case {}

instance SemigroupIn Void3 f where
    biretract = \case {}
    binterpret _ _ = \case {}

instance Associative Comp where
    type NonEmptyBy Comp = Free1
    associating = isoF to_ from_
      where
        to_   (x :>>= y) = (x :>>= (unComp . y)) :>>= id
        from_ ((x :>>= y) :>>= z) = x :>>= ((:>>= z) . y)

    appendNEB (x :>>= y) = x >>- y
    matchNEB = matchFree1

    consNEB (x :>>= y) = liftFree1 x >>- y
    toNEB   (x :>>= g) = liftFree1 x >>- inject . g

instance Bind f => SemigroupIn Comp f where
    biretract      (x :>>= y) = x >>- y
    binterpret f g (x :>>= y) = f x >>- (g . y)

---- data TC f a = TCA (f a) Bool
----             | TCB (Maybe (f a)) (TC f a)
--                -- sparse, non-empty list
--                -- and the last item has a Bool
--                -- aka sparse non-empty list tagged with a bool

instance Associative Joker where
    type NonEmptyBy Joker = Flagged
    associating = isoF (Joker . Joker    . runJoker)
                       (Joker . runJoker . runJoker)
    appendNEB (Joker (Flagged _ x)) = Flagged True x
    matchNEB (Flagged False x) = L1 x
    matchNEB (Flagged True  x) = R1 $ Joker x

instance SemigroupIn Joker f where
    biretract = runJoker
    binterpret f _ = f . runJoker

instance Associative LeftF where
    type NonEmptyBy LeftF = Flagged
    associating = isoF (LeftF . LeftF    . runLeftF)
                       (LeftF . runLeftF . runLeftF)

    appendNEB = hbind (Flagged True) . runLeftF
    matchNEB (Flagged False x) = L1 x
    matchNEB (Flagged True  x) = R1 $ LeftF x

    consNEB = Flagged True . runLeftF
    toNEB   = Flagged True . runLeftF

instance SemigroupIn LeftF f where
    biretract      = runLeftF
    binterpret f _ = f . runLeftF

instance Associative RightF where
    type NonEmptyBy RightF = Step
    associating = isoF (RightF . runRightF . runRightF)
                       (RightF . RightF    . runRightF)

    appendNEB = stepUp . R1 . runRightF
    matchNEB  = hright RightF . stepDown

    consNEB   = stepUp . R1 . runRightF
    toNEB     = Step 1 . runRightF

instance SemigroupIn RightF f where
    biretract      = runRightF
    binterpret _ g = g . runRightF
