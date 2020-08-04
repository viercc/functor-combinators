
module Data.Functor.Contravariant.Divisible.Free (
    Div(..)
  , hoistDiv, liftDiv
  , Div1(..)
  , hoistDiv1, liftDiv1, toDiv
  , Dec(..)
  , hoistDec, liftDec
  , Dec1(..)
  , hoistDec1, liftDec1, toDec
  ) where

import           Control.Natural
import           Data.Bifunctor
import           Data.Bifunctor.Assoc
import           Data.Functor.Contravariant
import           Data.Functor.Contravariant.Divise
import           Data.Functor.Contravariant.Divisible
import           Data.HFunctor
import           Data.HFunctor.Interpret
import           Data.Kind
import           Data.Void

-- | The free 'Divisible'.  Used to sequence multiple contravariant
-- consumers, splitting out the input across all consumers.
data Div :: (Type -> Type) -> Type -> Type where
    Conquer :: Div f a
    Divide  :: (a -> (b, c)) -> f b -> Div f c -> Div f a

instance Contravariant (Div f) where
    contramap :: forall a b. (a -> b) -> Div f b -> Div f a
    contramap f = \case
      Conquer       -> Conquer
      Divide g x xs -> Divide (g . f) x xs

instance Divise (Div f) where
    divise f = \case
      Conquer       -> contramap (snd . f)
      Divide g x xs -> Divide (assoc . first g . f) x
                     . divise id xs
instance Divisible (Div f) where
    conquer  = Conquer
    divide   = divise

hoistDiv :: forall f g. (f ~> g) -> Div f ~> Div g
hoistDiv f = go
  where
    go :: Div f ~> Div g
    go = \case
      Conquer       -> Conquer
      Divide g x xs -> Divide g (f x) (go xs)

liftDiv :: f ~> Div f
liftDiv x = Divide (,()) x Conquer

runDiv :: forall f g. Divisible g => (f ~> g) -> Div f ~> g
runDiv f = go
  where
    go :: Div f ~> g
    go = \case
      Conquer       -> conquer
      Divide g x xs -> divide g (f x) (go xs)

instance HFunctor Div where
    hmap = hoistDiv
instance Inject Div where
    inject = liftDiv
instance Divisible f => Interpret Div f where
    interpret = runDiv

-- | The free 'Divise': a non-empty version of 'Div'.
data Div1 :: (Type -> Type) -> Type -> Type where
    Div1 :: (a -> (b, c)) -> f b -> Div f c -> Div1 f a

instance Contravariant (Div1 f) where
    contramap f (Div1 g x xs) = Div1 (g . f) x xs
instance Divise (Div1 f) where
    divise f (Div1 g x xs) = Div1 (assoc . first g . f) x
                           . divise id xs
                           . toDiv

instance HFunctor Div1 where
    hmap = hoistDiv1
instance Inject Div1 where
    inject = liftDiv1
instance Divise f => Interpret Div1 f where
    interpret = runDiv1

-- | A 'Div1' is a "non-empty" 'Div'; this function "forgets" the non-empty
-- property and turns it back into a normal 'Div'.
toDiv :: Div1 f a -> Div f a
toDiv (Div1 f x xs) = Divide f x xs

hoistDiv1 :: (f ~> g) -> Div1 f ~> Div1 g
hoistDiv1 f (Div1 g x xs) = Div1 g (f x) (hoistDiv f xs)

liftDiv1 :: f ~> Div1 f
liftDiv1 f = Div1 (,()) f Conquer

runDiv1 :: Divise g => (f ~> g) -> Div1 f ~> g
runDiv1 f (Div1 g x xs) = runDiv1_ f g x xs

runDiv1_
    :: forall f g a b c. Divise g
    => (f ~> g)
    -> (a -> (b, c))
    -> f b
    -> Div f c
    -> g a
runDiv1_ f = go
  where
    go :: (x -> (y, z)) -> f y -> Div f z -> g x
    go g x = \case
      Conquer       -> contramap (fst . g) (f x)
      Divide h y ys -> divise g (f x) (go h y ys)


-- | The free 'Choice'.  Used to aggregate multiple possible consumers,
-- directing the input into an appropriate consumer.
data Dec :: (Type -> Type) -> Type -> Type where
    Lose   :: (a -> Void) -> Dec f a
    Choose :: (a -> Either b c) -> f b -> Dec f c -> Dec f a

instance Contravariant (Dec f) where
    contramap f = \case
      Lose   g      -> Lose   (g . f)
      Choose g x xs -> Choose (g . f) x xs
instance Choice (Dec f) where
    choice f = \case
      Lose   g      -> contramap (either (absurd . g) id . f)
      Choose g x xs -> Choose (assoc . first g . f) x
                     . choice id xs
instance Loss (Dec f) where
    loss = Lose
instance HFunctor Dec where
    hmap = hoistDec
instance Inject Dec where
    inject = liftDec
instance Loss f => Interpret Dec f where
    interpret = runDec

hoistDec :: forall f g. (f ~> g) -> Dec f ~> Dec g
hoistDec f = go
  where
    go :: Dec f ~> Dec g
    go = \case
      Lose g -> Lose g
      Choose g x xs -> Choose g (f x) (go xs)

liftDec :: f ~> Dec f
liftDec x = Choose Left x (Lose id)

runDec :: forall f g. Loss g => (f ~> g) -> Dec f ~> g
runDec f = go
  where
    go :: Dec f ~> g
    go = \case
      Lose g -> loss g
      Choose g x xs -> choice g (f x) (go xs)


-- | The free 'Choice': a non-empty version of 'Dec'.
data Dec1 :: (Type -> Type) -> Type -> Type where
    Dec1 :: (a -> Either b c) -> f b -> Dec f c -> Dec1 f a

-- | A 'Dec1' is a "non-empty" 'Dec'; this function "forgets" the non-empty
-- property and turns it back into a normal 'Dec'.
toDec :: Dec1 f a -> Dec f a
toDec (Dec1 f x xs) = Choose f x xs

instance Contravariant (Dec1 f) where
    contramap f (Dec1 g x xs) = Dec1 (g . f) x xs
instance Choice (Dec1 f) where
    choice f (Dec1 g x xs) = Dec1 (assoc . first g . f) x
                           . choice id xs
                           . toDec
instance HFunctor Dec1 where
    hmap = hoistDec1
instance Inject Dec1 where
    inject = liftDec1
instance Choice f => Interpret Dec1 f where
    interpret = runDec1

hoistDec1 :: forall f g. (f ~> g) -> Dec1 f ~> Dec1 g
hoistDec1 f (Dec1 g x xs) = Dec1 g (f x) (hoistDec f xs)

liftDec1 :: f ~> Dec1 f
liftDec1 x = Dec1 Left x (Lose id)

runDec1 :: Choice g => (f ~> g) -> Dec1 f ~> g
runDec1 f (Dec1 g x xs) = runDec1_ f g x xs

runDec1_
    :: forall f g a b c. Choice g
    => (f ~> g)
    -> (a -> Either b c)
    -> f b
    -> Dec f c
    -> g a
runDec1_ f = go
  where
    go :: (x -> Either y z) -> f y -> Dec f z -> g x
    go g x = \case
      Lose h -> contramap (either id (absurd . h) . g) (f x)
      Choose h y ys -> choice g (f x) (go h y ys)