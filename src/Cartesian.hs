-- Random stuff that we need for Cartesian cubicaltt
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances,
             GeneralizedNewtypeDeriving, TupleSections, UndecidableInstances #-}
module Cartesian where

import Control.Applicative
import Control.Monad.Gen
import Data.List
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Traversable as T
import Control.Monad.Trans

-- The evaluation monad
type Eval a = GenT Int IO a


instance (MonadTrans t, MonadFail m, Monad (t m)) => MonadFail (t m)  where
  fail = lift . fail

runEval :: Eval a -> IO a
runEval = runGenT

data Name = N String
          | Gen {-# UNPACK #-} !Int
  deriving (Eq,Ord)

instance Show Name where
  show (N i) = i
  show (Gen x)  = 'i' : show x

swapName :: Name -> (Name,Name) -> Name
swapName k (i,j) | k == i    = j
                 | k == j    = i
                 | otherwise = k

-- | Directions

-- Maybe merge with II?
data Dir = Zero | One
  deriving (Eq,Ord)

instance Show Dir where
  show Zero = "0"
  show One  = "1"

instance Num Dir where
  Zero + Zero = Zero
  _    + _    = One

  Zero * _ = Zero
  One  * x = x

  abs      = id
  signum _ = One

  negate Zero = One
  negate One  = Zero

  fromInteger 0 = Zero
  fromInteger 1 = One
  fromInteger _ = error "fromInteger Dir"

-- | Interval

data II = Dir Dir
        | Name Name
  deriving (Eq,Ord)

instance Show II where
  show (Dir x) = show x
  show (Name x) = show x

class ToII a where
  toII :: a -> II

instance ToII II where
  toII = id

instance ToII Name where
  toII = Name

instance ToII Dir where
  toII = Dir

-- This is a bit of a hack
instance Num II where
  (+) = undefined
  (*) = undefined
  abs = undefined
  signum = undefined
  negate= undefined
  fromInteger 0 = Dir Zero
  fromInteger 1 = Dir One
  fromInteger _ = error "fromInteger Dir"

-- | Equations

-- Invariant: Eqn r s means r >= s
-- Important: Name > Dir
data Eqn = Eqn II II
  deriving (Eq,Ord)

eqn :: (II,II) -> Eqn
eqn (r,s) = Eqn (max r s) (min r s)

isConsistent :: Eqn -> Bool
isConsistent (Eqn (Dir Zero) (Dir One)) = False -- This is not necessary
isConsistent (Eqn (Dir One) (Dir Zero)) = False
isConsistent _ = True

instance Show Eqn where
  show (Eqn r s) = "(" ++ show r ++ " = " ++ show s ++ ")"

-- Check if two equations are compatible
compatible :: Eqn -> Eqn -> Bool
compatible (Eqn i (Dir d)) (Eqn j (Dir d')) | i == j = d == d'
compatible _ _ = True

allCompatible :: [Eqn] -> [(Eqn,Eqn)]
allCompatible []     = []
allCompatible (f:fs) = map (f,) (filter (compatible f) fs) ++ allCompatible fs

(~>) :: ToII a => a -> II -> Eqn
i ~> d = eqn (toII i,d)

-- | Nominal

class Nominal a where
--  support :: a -> [Name]
  occurs :: Name -> a -> Bool
--  occurs x v = x `elem` support v
  subst   :: a -> (Name,II) -> Eval a
  swap    :: a -> (Name,Name) -> a

notOccurs :: Nominal a => Name -> a -> Bool
notOccurs i x = not (i `occurs` x)

fresh :: Eval Name
fresh = do
  n <- gen
  return $ Gen n

freshs :: Eval [Name]
freshs = do
  n <- fresh
  ns <- freshs
  return (n : ns)

newtype Nameless a = Nameless { unNameless :: a }
  deriving (Eq, Ord)

instance Nominal (Nameless a) where
--  support _ = []
  occurs _ _ = False
  subst x _   = return x
  swap x _  = x

instance Nominal () where
--  support () = []
  occurs _ _ = False
  subst () _   = return ()
  swap () _  = ()

instance (Nominal a, Nominal b) => Nominal (a, b) where
--  support (a, b) = support a `union` support b
  occurs x (a,b) = occurs x a || occurs x b
  subst (a,b) f  = (,) <$> subst a f <*> subst b f
  swap (a,b) n   = (swap a n,swap b n)

instance (Nominal a, Nominal b, Nominal c) => Nominal (a, b, c) where
--  support (a,b,c) = unions [support a, support b, support c]
  occurs x (a,b,c) = or [occurs x a,occurs x b,occurs x c]
  subst (a,b,c) f = do
    af <- subst a f
    bf <- subst b f
    cf <- subst c f
    return (af,bf,cf)
  swap (a,b,c) n  = (swap a n,swap b n,swap c n)

instance (Nominal a, Nominal b, Nominal c, Nominal d) =>
         Nominal (a, b, c, d) where
--  support (a,b,c,d) = unions [support a, support b, support c, support d]
  occurs x (a,b,c,d) = or [occurs x a,occurs x b,occurs x c,occurs x d]
  subst (a,b,c,d) f = do
    af <- subst a f
    bf <- subst b f
    cf <- subst c f
    df <- subst d f
    return (af,bf,cf,df)
  swap (a,b,c,d) n  = (swap a n,swap b n,swap c n,swap d n)

instance (Nominal a, Nominal b, Nominal c, Nominal d, Nominal e) =>
         Nominal (a, b, c, d, e) where
  -- support (a,b,c,d,e)  =
  --   unions [support a, support b, support c, support d, support e]
  occurs x (a,b,c,d,e) =
    or [occurs x a,occurs x b,occurs x c,occurs x d,occurs x e]
  subst (a,b,c,d,e) f = do
    af <- subst a f
    bf <- subst b f
    cf <- subst c f
    df <- subst d f
    ef <- subst e f
    return (af,bf,cf,df,ef)
  swap (a,b,c,d,e) n =
    (swap a n,swap b n,swap c n,swap d n,swap e n)

instance (Nominal a, Nominal b, Nominal c, Nominal d, Nominal e, Nominal h) =>
         Nominal (a, b, c, d, e, h) where
  -- support (a,b,c,d,e,h) =
  --   unions [support a, support b, support c, support d, support e, support h]
  occurs x (a,b,c,d,e,h) =
    or [occurs x a,occurs x b,occurs x c,occurs x d,occurs x e,occurs x h]
  subst (a,b,c,d,e,h) f = do
    af <- subst a f
    bf <- subst b f
    cf <- subst c f
    df <- subst d f
    ef <- subst e f
    hf <- subst h f
    return (af,bf,cf,df,ef,hf)
  swap (a,b,c,d,e,h) n  =
    (swap a n,swap b n,swap c n,swap d n,swap e n,swap h n)

instance Nominal a => Nominal [a]  where
--  support xs  = unions (map support xs)
  occurs x xs = any (occurs x) xs
  subst xs f  = T.sequence [ subst x f | x <- xs ]
  swap xs n   = [ swap x n | x <- xs ]

instance Nominal a => Nominal (Maybe a)  where
--  support    = maybe [] support
  occurs x   = maybe False (occurs x)
  subst v f  = T.sequence (fmap (\y -> subst y f) v)
  swap a n   = fmap (`swap` n) a

instance Nominal II where
  -- support (Dir _)        = []
  -- support (Name i)       = [i]

  occurs x (Dir _)  = False
  occurs x (Name i) = x == i

  subst (Dir b)  (i,r) = return $ Dir b
  subst (Name j) (i,r) | i == j    = return r
                       | otherwise = return $ Name j

  swap (Dir b)  (i,j) = Dir b
  swap (Name k) (i,j) | k == i    = Name j
                      | k == j    = Name i
                      | otherwise = Name k

instance Nominal Eqn where
  occurs x (Eqn r s) = occurs x r || occurs x s
  subst (Eqn r s) f = curry eqn <$> subst r f <*> subst s f
  swap (Eqn r s) f = eqn (swap r f, swap s f)

supportII :: II -> [Name]
supportII (Dir _)  = []
supportII (Name i) = [i]

-- Invariant: No false equations; turns into Triv if any true equations.
data System a = Sys (Map.Map Eqn a)
              | Triv a
  deriving Eq

instance Show a => Show (System a) where
  show (Sys xs) = case Map.toList xs of
    [] -> "[]"
    ts -> "[ " ++ intercalate ", " [ show alpha ++ " -> " ++ show u
                                   | (alpha,u) <- ts ] ++ " ]"
  show (Triv a) = "[ T -> " ++ show a ++ " ]"

-- The empty system
eps :: System a
eps = Sys (Map.empty)

-- relies on (and preserves) System invariant
insertSystem :: (Eqn,a) -> System a -> System a
insertSystem _       (Triv a) = Triv a
insertSystem (eqn,a) (Sys xs) = case eqn of
  -- equation is always false
  Eqn (Dir One) (Dir Zero) -> Sys xs
  -- equation is always true
  Eqn r s | r == s -> Triv a
  -- otherwise
  Eqn r s -> Sys (Map.insert eqn a xs)

insertsSystem :: [(Eqn,a)] -> System a -> System a
insertsSystem xs sys = foldr insertSystem sys xs

mkSystem :: [(Eqn,a)] -> System a
mkSystem xs = insertsSystem xs eps

mergeSystem :: System a -> System a -> System a
mergeSystem (Triv x) _ = Triv x
mergeSystem _ (Triv y) = Triv y
mergeSystem (Sys xs) ys = Map.toList xs `insertsSystem` ys

-- allSystem :: Name -> System a -> System a
-- allSystem i (Sys xs) = Sys (Map.filterWithKey (\eqn _ -> i `occurs` eqn) xs)
-- allSystem _ (Triv x) = Triv x

-- notAllSystem :: Name -> System a -> System a
-- notAllSystem i (Sys xs) = Sys (Map.filterWithKey (\eqn _ -> i `notOccurs` eqn) xs)
-- notAllSystem _ (Triv x) = Triv x

instance Nominal a => Nominal (System a) where
  occurs x (Sys xs) = Map.foldrWithKey fn False xs
    where fn eqn a accum = accum || occurs x eqn || occurs x a
  occurs x (Triv a) = occurs x a

  subst (Sys xs) f =
    mkSystem <$> mapM (\(eqn,a) -> (,) <$> subst eqn f <*> subst a f) (Map.assocs xs)
  subst (Triv x) f = Triv <$> subst x f

  swap (Sys xs) ij = Map.foldrWithKey fn eps xs
    where fn eqn a = insertSystem (swap eqn ij,swap a ij)
  swap (Triv a) ij = Triv (swap a ij)

toSubst :: Eqn -> (Name,II)
toSubst (Eqn (Name i) r) = (i,r)
toSubst eqn = error $ "toSubst: encountered " ++ show eqn ++ " in system"

face :: Nominal a => a -> Eqn -> Eval a
face a (Eqn (Name (N "_")) (Name (N "_"))) = return a -- handle dummy case separately
face a f = a `subst` toSubst f

-- carve a using the same shape as the system b
border :: a -> System b -> System a
border v (Sys xs) = Sys (Map.map (const v) xs)
border v (Triv _) = Triv v

shape :: System a -> System ()
shape = border ()

intersectWith :: (a -> b -> c) -> System a -> System b -> System c
intersectWith f (Triv x) (Triv y) = Triv (f x y)
intersectWith f (Sys xs) (Sys ys) = Sys (Map.intersectionWith f xs ys)
intersectWith _ _ _ = error "intersectWith not matching input"

runSystem :: System (Eval a) -> Eval (System a)
runSystem (Triv x) = Triv <$> x
runSystem (Sys xs) = do
  xs' <- T.sequence xs
  return $ Sys xs'

-- TODO: optimize so that we don't apply the face everywhere before computing this
-- assumes alpha <= shape us
-- proj :: (Nominal a, Show a) => System a -> (Name,II) -> a
-- proj us ir = case us `subst` ir of
--   Triv a -> a
--   _ -> error "proj"

eqnSupport :: System a -> [Name]
eqnSupport (Triv _) = []
eqnSupport (Sys xs) = concatMap support (Map.keys xs)
  where support (Eqn (Name i) (Dir _)) = [i]
        support (Eqn (Name i) (Name j)) = [i,j]
        support eqn = error $ "eqnSupport: encountered " ++ show eqn ++ " in system"
