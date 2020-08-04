{-# LANGUAGE DerivingVia #-}

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
-- 'biretract' :: 'SemigroupIn' t f => t f f ~> f
-- @
--
-- which lets you fully "mix" together the two input functors.
--
-- @
-- 'biretract' :: (f ':+:' f) a -> f a
-- biretract :: 'Plus' f => (f ':*:' f) a -> f a
-- biretract :: 'Applicative' f => 'Day' f f a -> f a
-- biretract :: 'Monad' f => 'Comp' f f a -> f a
-- @
--
-- See "Data.HBifunctor.Tensor" for the next stage of structure in tensors
-- and moving in and out of them.
module Data.HBifunctor.Associative (
  -- * 'Associative'
    Associative(..)
  , assoc
  , disassoc
  -- * 'SemigroupIn'
  , SemigroupIn(..)
  , matchingNE
  , retractNE
  , interpretNE
  -- ** Utility
  , biget
  , bicollect
  , (!*!)
  , (!$!)
  , (!+!)
  , WrapHBF(..)
  , WrapNE(..)
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
import           Data.Constraint.Trivial
import           Data.Data
import           Data.Foldable
import           Data.Functor.Apply.Free
import           Data.Functor.Bind
import           Data.Functor.Classes
import           Data.Functor.Contravariant
import           Data.Functor.Contravariant.Decide
import           Data.Functor.Contravariant.Divise
import           Data.Functor.Contravariant.Divisible.Free
import           Data.Functor.Contravariant.Night          (Night(..))
import           Data.Functor.Day                          (Day(..))
import           Data.Functor.Identity
import           Data.Functor.Invariant
import           Data.Functor.Plus
import           Data.Functor.Product
import           Data.Functor.Sum
import           Data.Functor.These
import           Data.HBifunctor
import           Data.HFunctor
import           Data.HFunctor.Internal
import           Data.HFunctor.Interpret
import           Data.Kind
import           Data.List.NonEmpty                        (NonEmpty(..))
import           Data.Void
import           GHC.Generics
import qualified Data.Functor.Contravariant.Coyoneda       as CCY
import qualified Data.Functor.Contravariant.Day            as CD
import qualified Data.Functor.Contravariant.Night          as N
import qualified Data.Functor.Day                          as D
import qualified Data.List.NonEmpty                        as NE
import qualified Data.Map.NonEmpty                         as NEM

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
--
-- Formally, we can say that @t@ enriches a the category of
-- endofunctors with semigroup strcture: it turns our endofunctor category
-- into a "semigroupoidal category".
--
-- Different instances of @t@ each enrich the endofunctor category in
-- different ways, giving a different semigroupoidal category.
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
    -- x ':*:' y       ~ NonEmptyF (x :| [y])     ~ 'toNonEmptyBy' (x :*: y)
    -- x :*: y :*: z ~ NonEmptyF (x :| [y,z])
    -- -- etc.
    -- @
    --
    -- You can create an "singleton" one with 'inject', or else one from
    -- a single @t f f@ with 'toNonEmptyBy'.
    --
    -- See 'Data.HBifunctor.Tensor.ListBy' for a "possibly empty" version
    -- of this type.
    type NonEmptyBy t :: (Type -> Type) -> Type -> Type
    type FunctorBy t :: (Type -> Type) -> Constraint
    type FunctorBy t = Unconstrained

    -- | The isomorphism between @t f (t g h) a@ and @t (t f g) h a@.  To
    -- use this isomorphism, see 'assoc' and 'disassoc'.
    associating
        :: (FunctorBy t f, FunctorBy t g, FunctorBy t h)
        => t f (t g h) <~> t (t f g) h

    -- | If a @'NonEmptyBy' t f@ represents multiple applications of @t f@ to
    -- itself, then we can also "append" two @'NonEmptyBy' t f@s applied to
    -- themselves into one giant @'NonEmptyBy' t f@ containing all of the @t f@s.
    --
    -- Note that this essentially gives an instance for @'SemigroupIn'
    -- t (NonEmptyBy t f)@, for any functor @f@.
    appendNE :: t (NonEmptyBy t f) (NonEmptyBy t f) ~> NonEmptyBy t f

    -- | If a @'NonEmptyBy' t f@ represents multiple applications of @t f@
    -- to itself, then we can split it based on whether or not it is just
    -- a single @f@ or at least one top-level application of @t f@.
    --
    -- Note that you can recursively "unroll" a 'NonEmptyBy' completely
    -- into a 'Data.HFunctor.Chain.Chain1' by using
    -- 'Data.HFunctor.Chain.unrollNE'.
    matchNE  :: FunctorBy t f => NonEmptyBy t f ~> f :+: t f (NonEmptyBy t f)

    -- | Prepend an application of @t f@ to the front of a @'NonEmptyBy' t f@.
    consNE :: t f (NonEmptyBy t f) ~> NonEmptyBy t f
    consNE = appendNE . hleft inject

    -- | Embed a direct application of @f@ to itself into a @'NonEmptyBy' t f@.
    toNonEmptyBy :: t f f ~> NonEmptyBy t f
    toNonEmptyBy = consNE . hright inject

    {-# MINIMAL associating, appendNE, matchNE #-}

-- | Reassociate an application of @t@.
assoc
    :: (Associative t, FunctorBy t f, FunctorBy t g, FunctorBy t h)
    => t f (t g h)
    ~> t (t f g) h
assoc = viewF associating

-- | Reassociate an application of @t@.
disassoc
    :: (Associative t, FunctorBy t f, FunctorBy t g, FunctorBy t h)
    => t (t f g) h
    ~> t f (t g h)
disassoc = reviewF associating

-- | For different @'Associative' t@, we have functors @f@ that we can
-- "squash", using 'biretract':
--
-- @
-- t f f ~> f
-- @
--
-- This gives us the ability to squash applications of @t@.
--
-- Formally, if we have @'Associative' t@, we are enriching the category of
-- endofunctors with semigroup structure, turning it into a semigroupoidal
-- category.  Different choices of @t@ give different semigroupoidal
-- categories.
--
-- A functor @f@ is known as a "semigroup in the (semigroupoidal) category
-- of endofunctors on @t@" if we can 'biretract':
--
-- @
-- t f f ~> f
-- @
--
-- This gives us a few interesting results in category theory, which you
-- can stil reading about if you don't care:
--
-- *  /All/ functors are semigroups in the semigroupoidal category
--    on ':+:'
-- *  The class of functors that are semigroups in the semigroupoidal
--    category on ':*:' is exactly the functors that are instances of
--    'Alt'.
-- *  The class of functors that are semigroups in the semigroupoidal
--    category on 'Day' is exactly the functors that are instances of
--    'Apply'.
-- *  The class of functors that are semigroups in the semigroupoidal
--    category on 'Comp' is exactly the functors that are instances of
--    'Bind'.
--
-- Note that instances of this class are /intended/ to be written with @t@
-- as a fixed type constructor, and @f@ to be allowed to vary freely:
--
-- @
-- instance Bind f => SemigroupIn Comp f
-- @
--
-- Any other sort of instance and it's easy to run into problems with type
-- inference.  If you want to write an instance that's "polymorphic" on
-- tensor choice, use the 'WrapHBF' newtype wrapper over a type variable,
-- where the second argument also uses a type constructor:
--
-- @
-- instance SemigroupIn (WrapHBF t) (MyFunctor t i)
-- @
--
-- This will prevent problems with overloaded instances.
class (Associative t, FunctorBy t f) => SemigroupIn t f where
    -- | The 'HBifunctor' analogy of 'retract'. It retracts /both/ @f@s
    -- into a single @f@, effectively fully mixing them together.
    --
    -- This function makes @f@ a semigroup in the category of endofunctors
    -- with respect to tensor @t@.
    biretract :: t f f ~> f

    default biretract :: Interpret (NonEmptyBy t) f => t f f ~> f
    biretract = retract . consNE . hright inject

    -- | The 'HBifunctor' analogy of 'interpret'.  It takes two
    -- interpreting functions, and mixes them together into a target
    -- functor @h@.
    --
    -- Note that this is useful in the poly-kinded case, but it is not possible
    -- to define generically for all 'SemigroupIn' because it only is defined
    -- for @Type -> Type@ inputes.  See '!+!' for a version that is poly-kinded
    -- for ':+:' in specific.
    binterpret
        :: g ~> f
        -> h ~> f
        -> t g h ~> f

    default binterpret :: Interpret (NonEmptyBy t) f => (g ~> f) -> (h ~> f) -> t g h ~> f
    binterpret f g = retract . toNonEmptyBy . hbimap f g

-- | An implementation of 'retract' that works for any instance of
-- @'SemigroupIn' t@ for @'NonEmptyBy' t@.
--
-- Can be useful as a default implementation if you already have
-- 'SemigroupIn' implemented.
retractNE :: forall t f. SemigroupIn t f => NonEmptyBy t f ~> f
retractNE = (id !*! biretract @t . hright (retractNE @t))
          . matchNE @t

-- | An implementation of 'interpret' that works for any instance of
-- @'SemigroupIn' t@ for @'NonEmptyBy' t@.
--
-- Can be useful as a default implementation if you already have
-- 'SemigroupIn' implemented.
interpretNE :: forall t g f. SemigroupIn t f => (g ~> f) -> NonEmptyBy t g ~> f
interpretNE f = retractNE @t . hmap f

-- | An @'NonEmptyBy' t f@ represents the successive application of @t@ to @f@,
-- over and over again.   So, that means that an @'NonEmptyBy' t f@ must either be
-- a single @f@, or an @t f (NonEmptyBy t f)@.
--
-- 'matchingNE' states that these two are isomorphic.  Use 'matchNE' and
-- @'inject' '!*!' 'consNE'@ to convert between one and the other.
matchingNE :: (Associative t, FunctorBy t f) => NonEmptyBy t f <~> f :+: t f (NonEmptyBy t f)
matchingNE = isoF matchNE (inject !*! consNE)

-- | Useful wrapper over 'binterpret' to allow you to directly extract
-- a value @b@ out of the @t f a@, if you can convert @f x@ into @b@.
--
-- Note that depending on the constraints on @f@ in @'SemigroupIn' t f@,
-- you may have extra constraints on @b@.
--
-- *    If @f@ is unconstrained, there are no constraints on @b@
-- *    If @f@ must be 'Apply', @b@ needs to be an instance of 'Semigroup'
-- *    If @f@ must be 'Applicative', @b@ needs to be an instance of 'Monoid'
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
--
-- Note that this is useful in the poly-kinded case, but it is not possible
-- to define generically for all 'SemigroupIn' because it only is defined
-- for @Type -> Type@ inputes.  See '!+!' for a version that is poly-kinded
-- for ':+:' in specific.
(!*!)
    :: SemigroupIn t h
    => (f ~> h)
    -> (g ~> h)
    -> t f g
    ~> h
(!*!) = binterpret
infixr 5 !*!

-- | A version of '!*!' specifically for ':+:' that is poly-kinded
(!+!)
    :: (f ~> h)
    -> (g ~> h)
    -> (f :+: g)
    ~> h
(!+!) f g = \case
    L1 x -> f x
    R1 y -> g y
infixr 5 !+!


-- | Useful wrapper over 'biget' to allow you to collect a @b@ from all
-- instances of @f@ and @g@ inside a @t f g a@.
--
-- This will work if the constraint on @f@ for @'SemigroupIn' t f@ is
-- 'Apply' or 'Applicative', or if it is unconstrained.
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

    appendNE (NonEmptyF xs :*: NonEmptyF ys) = NonEmptyF (xs <> ys)
    matchNE x = case ys of
        L1 ~Proxy -> L1 y
        R1 zs     -> R1 $ y :*: zs
      where
        y :*: ys = fromListF `hright` nonEmptyProd x

    consNE (x :*: NonEmptyF xs) = NonEmptyF $ x :| toList xs
    toNonEmptyBy   (x :*: y           ) = NonEmptyF $ x :| [y]

-- | Instances of 'Alt' are semigroups in the semigroupoidal category on
-- ':*:'.
instance Alt f => SemigroupIn (:*:) f where
    biretract (x :*: y) = x <!> y
    binterpret f g (x :*: y) = f x <!> g y

instance Associative Product where
    type NonEmptyBy Product = NonEmptyF

    associating = isoF to_ from_
      where
        to_   (Pair x (Pair y z)) = Pair (Pair x y) z
        from_ (Pair (Pair x y) z) = Pair x (Pair y z)

    appendNE (NonEmptyF xs `Pair` NonEmptyF ys) = NonEmptyF (xs <> ys)
    matchNE x = case ys of
        L1 ~Proxy -> L1 y
        R1 zs     -> R1 $ Pair y zs
      where
        y :*: ys = fromListF `hright` nonEmptyProd x

    consNE (x `Pair` NonEmptyF xs) = NonEmptyF $ x :| toList xs
    toNonEmptyBy   (x `Pair` y           ) = NonEmptyF $ x :| [y]

-- | Instances of 'Alt' are semigroups in the semigroupoidal category on
-- 'Product'.
instance Alt f => SemigroupIn Product f where
    biretract (Pair x y) = x <!> y
    binterpret f g (Pair x y) = f x <!> g y

instance Associative Day where
    type NonEmptyBy Day = Ap1
    type FunctorBy Day = Functor
    associating = isoF D.assoc D.disassoc

    appendNE (Day x y z) = z <$> x <.> y
    matchNE a = case fromAp `hright` ap1Day a of
      Day x y z -> case y of
        L1 (Identity y') -> L1 $ (`z` y') <$> x
        R1 ys            -> R1 $ Day x ys z

    consNE (Day x y z) = Ap1 x $ flip z <$> toAp y
    toNonEmptyBy   (Day x y z) = z <$> inject x <.> inject y

-- | Instances of 'Apply' are semigroups in the semigroupoidal category on
-- 'Day'.
instance Apply f => SemigroupIn Day f where
    biretract (Day x y z) = z <$> x <.> y
    binterpret f g (Day x y z) = z <$> f x <.> g y

instance Associative CD.Day where
    type NonEmptyBy CD.Day = ComposeT NonEmptyF CCY.Coyoneda
    type FunctorBy CD.Day = Contravariant
    associating = isoF CD.assoc CD.disassoc

    appendNE (CD.Day (ComposeT (NonEmptyF xs)) (ComposeT (NonEmptyF ys)) f) = ComposeT $
        NonEmptyF $ (fmap . contramap) (fst . f) xs
                 <> (fmap . contramap) (snd . f) ys
    matchNE (ComposeT (NonEmptyF (x :| xs))) = case NE.nonEmpty xs of
      Nothing -> L1 $ CCY.lowerCoyoneda x
      Just ys -> R1 $ CD.Day (CCY.lowerCoyoneda x) (ComposeT (NonEmptyF ys)) (\y -> (y,y))

    consNE (CD.Day x (ComposeT (NonEmptyF xs)) f) = ComposeT $ NonEmptyF $
        CCY.Coyoneda (fst . f) x :| (map . contramap) (snd . f) (toList xs)
    toNonEmptyBy (CD.Day x y f) = ComposeT $ NonEmptyF $
        CCY.Coyoneda (fst . f) x :| [CCY.Coyoneda (snd . f) y]

    -- appendNE (CD.Day x y f) = divise f x y
    -- matchNE (Div1 f x xs) = case xs of
    --   Conquer -> L1 $ contramap (fst . f) x
    --   Divide g y ys -> R1 $ CD.Day x (Div1 g y ys) f

    -- consNE (CD.Day x y f) = Div1 f x (toDiv y)
    -- toNonEmptyBy (CD.Day x y f) = Div1 f x (inject y)

instance Divise f => SemigroupIn CD.Day f where
    biretract      (CD.Day x y f) = divise f x y
    binterpret f g (CD.Day x y h) = divise h (f x) (g y)

instance Associative Night where
    type NonEmptyBy Night = Dec1
    type FunctorBy Night = Contravariant
    associating = isoF N.assoc N.unassoc

    appendNE (Night x y f) = decide f x y
    matchNE (Dec1 f x xs) = case xs of
      Lose g -> L1 $ contramap (either id (absurd . g) . f) x
      Choose g y ys -> R1 $ Night x (Dec1 g y ys) f

    consNE (Night x y f) = Dec1 f x (toDec y)
    toNonEmptyBy (Night x y f) = Dec1 f x (inject y)

instance Decide f => SemigroupIn Night f where
    biretract      (Night x y f) = decide f x y
    binterpret f g (Night x y h) = decide h (f x) (g y)

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

    appendNE = \case
      L1 (Step i x) -> Step (i + 1) x
      R1 (Step i y) -> Step (i + 2) y
    matchNE = hright stepDown . stepDown

    consNE = stepUp . R1 . stepUp
    toNonEmptyBy = \case
      L1 x -> Step 1 x
      R1 y -> Step 2 y

-- | All functors are semigroups in the semigroupoidal category on ':+:'.
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

    appendNE = \case
      InL (Step i x) -> Step (i + 1) x
      InR (Step i y) -> Step (i + 2) y
    matchNE = hright (viewF sumSum . stepDown) . stepDown

    consNE = stepUp . R1 . stepUp . reviewF sumSum
    toNonEmptyBy = \case
      InL x -> Step 1 x
      InR y -> Step 2 y

-- | All functors are semigroups in the semigroupoidal category on 'Sum'.
instance SemigroupIn Sum f where
    biretract = \case
      InR x -> x
      InL y -> y
    binterpret f g = \case
      InL x -> f x
      InR y -> g y

-- | Ideally here 'NonEmptyBy' would be equivalent to 'Data.HBifunctor.Tensor.ListBy',
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

    appendNE s = ComposeT $ case s of
        This1  (ComposeT (Flagged _ q))                       ->
          Flagged True q
        That1                           (ComposeT (Flagged b q)) ->
          Flagged b        (stepsUp (That1 q))
        These1 (ComposeT (Flagged a q)) (ComposeT (Flagged b r)) ->
          Flagged (a || b) (q <> r)
    matchNE (ComposeT (Flagged isImpure q)) = case stepsDown q of
      This1  x
        | isImpure  -> R1 $ This1 x
        | otherwise -> L1 x
      That1    y    -> R1 . That1 . ComposeT $ Flagged isImpure y
      These1 x y    -> R1 . These1 x .  ComposeT $ Flagged isImpure y

    consNE s = ComposeT $ case s of
      This1  x                          -> Flagged True (inject x)
      That1    (ComposeT (Flagged b y)) -> Flagged b    (stepsUp (That1    y))
      These1 x (ComposeT (Flagged b y)) -> Flagged b    (stepsUp (These1 x y))
    toNonEmptyBy  s = ComposeT $ case s of
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

    appendNE = \case {}
    matchNE  = L1 . runIdentityT

    consNE = \case {}
    toNonEmptyBy   = \case {}

-- | All functors are semigroups in the semigroupoidal category on 'Void3'.
instance SemigroupIn Void3 f where
    biretract = \case {}
    binterpret _ _ = \case {}

instance Associative Comp where
    type NonEmptyBy Comp = Free1
    type FunctorBy Comp = Functor

    associating = isoF to_ from_
      where
        to_   (x :>>= y) = (x :>>= (unComp . y)) :>>= id
        from_ ((x :>>= y) :>>= z) = x :>>= ((:>>= z) . y)

    appendNE (x :>>= y) = x >>- y
    matchNE = matchFree1

    consNE (x :>>= y) = liftFree1 x >>- y
    toNonEmptyBy   (x :>>= g) = liftFree1 x >>- inject . g

-- | Instances of 'Bind' are semigroups in the semigroupoidal category on
-- 'Comp'.
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
    appendNE (Joker (Flagged _ x)) = Flagged True x
    matchNE (Flagged False x) = L1 x
    matchNE (Flagged True  x) = R1 $ Joker x

instance SemigroupIn Joker f where
    biretract = runJoker
    binterpret f _ = f . runJoker

instance Associative LeftF where
    type NonEmptyBy LeftF = Flagged
    associating = isoF (LeftF . LeftF    . runLeftF)
                       (LeftF . runLeftF . runLeftF)

    appendNE = hbind (Flagged True) . runLeftF
    matchNE (Flagged False x) = L1 x
    matchNE (Flagged True  x) = R1 $ LeftF x

    consNE = Flagged True . runLeftF
    toNonEmptyBy   = Flagged True . runLeftF

instance SemigroupIn LeftF f where
    biretract      = runLeftF
    binterpret f _ = f . runLeftF

instance Associative RightF where
    type NonEmptyBy RightF = Step

    associating = isoF (RightF . runRightF . runRightF)
                       (RightF . RightF    . runRightF)

    appendNE = stepUp . R1 . runRightF
    matchNE  = hright RightF . stepDown

    consNE   = stepUp . R1 . runRightF
    toNonEmptyBy     = Step 1 . runRightF

instance SemigroupIn RightF f where
    biretract      = runRightF
    binterpret _ g = g . runRightF

-- | A newtype wrapper meant to be used to define polymorphic 'SemigroupIn'
-- instances.  See documentation for 'SemigroupIn' for more information.
--
-- Please do not ever define an instance of 'SemigroupIn' "naked" on the
-- second parameter:
--
-- @
-- instance SemigroupIn (WrapHBF t) f
-- @
--
-- As that would globally ruin everything using 'WrapHBF'.
newtype WrapHBF t f g a = WrapHBF { unwrapHBF :: t f g a }
  deriving (Show, Read, Eq, Ord, Functor, Foldable, Traversable, Typeable, Generic, Data)

instance Show1 (t f g) => Show1 (WrapHBF t f g) where
    liftShowsPrec sp sl d (WrapHBF x) = showsUnaryWith (liftShowsPrec sp sl) "WrapHBF" d x

instance Eq1 (t f g) => Eq1 (WrapHBF t f g) where
    liftEq eq (WrapHBF x) (WrapHBF y) = liftEq eq x y

instance Ord1 (t f g) => Ord1 (WrapHBF t f g) where
    liftCompare c (WrapHBF x) (WrapHBF y) = liftCompare c x y

instance HBifunctor t => HBifunctor (WrapHBF t) where
    hbimap f g (WrapHBF x) = WrapHBF (hbimap f g x)
    hleft f (WrapHBF x) = WrapHBF (hleft f x)
    hright g (WrapHBF x) = WrapHBF (hright g x)

deriving via (WrappedHBifunctor (WrapHBF t) f)
    instance HBifunctor t => HFunctor (WrapHBF t f)

instance Associative t => Associative (WrapHBF t) where
    type NonEmptyBy (WrapHBF t) = NonEmptyBy t
    type FunctorBy (WrapHBF t) = FunctorBy t

    associating = isoF (hright unwrapHBF . unwrapHBF) (WrapHBF . hright WrapHBF)
                . associating @t
                . isoF (WrapHBF . hleft WrapHBF) (hleft unwrapHBF . unwrapHBF)

    appendNE     = appendNE . unwrapHBF
    matchNE      = hright WrapHBF . matchNE
    consNE       = consNE . unwrapHBF
    toNonEmptyBy = toNonEmptyBy . unwrapHBF

-- | Any @'NonEmptyBy' t f@ is a @'SemigroupIn' t@ if we have
-- @'Associative' t@. This newtype wrapper witnesses that fact.  We require
-- a newtype wrapper to avoid overlapping instances.
newtype WrapNE t f a = WrapNE { unwrapNE :: NonEmptyBy t f a }

instance Functor (NonEmptyBy t f) => Functor (WrapNE t f) where
    fmap f (WrapNE x) = WrapNE (fmap f x)

instance Contravariant (NonEmptyBy t f) => Contravariant (WrapNE t f) where
    contramap f (WrapNE x) = WrapNE (contramap f x)

instance Invariant (NonEmptyBy t f) => Invariant (WrapNE t f) where
    invmap f g (WrapNE x) = WrapNE (invmap f g x)

instance (Associative t, FunctorBy t f, FunctorBy t (WrapNE t f)) => SemigroupIn (WrapHBF t) (WrapNE t f) where
    biretract = WrapNE . appendNE . hbimap unwrapNE unwrapNE . unwrapHBF
    binterpret f g = biretract . hbimap f g

-- cdday :: (Contravariant f, Contravariant g) => CD.Day f g ~> (f :*: g)
-- cdday (CD.Day x y f) = contramap (fst . f) x :*: contramap (snd . f) y

-- daycd :: (f :*: g) ~> CD.Day f g
-- daycd (x :*: y) = CD.Day x y (\z -> (z,z))
