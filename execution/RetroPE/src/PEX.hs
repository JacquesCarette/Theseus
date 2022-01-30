
module PEX where

-- partial evaluation of a circuit;
-- here we only care if a variable is used or not

import Data.STRef
import Data.List (intercalate,group,sort,nub,intersect,(\\))
import Data.Maybe (catMaybes, maybe, fromMaybe, fromJust)
import qualified Data.Sequence as S

import Control.Monad 
import Control.Monad.ST

import System.Random (randomRIO)

import Text.Printf

import Circuits

----------------------------------------------------------------------------------------
{--

Approximate the full ANF by only keep track of ONE variable in each AND clause. We
will assume that x_{i+1} is more significant that x_{i} so we will approximate
x_5 && x_2 but just x_5

Next approximation in PEY keeps track of at most two variables

--}

type Literal = String

-- Ands []      = True
-- Ands [a,b,c] = a && b && c
-- but only keep on variable in list (msb)

newtype Ands = Ands { lits :: [Literal] }
  deriving (Eq,Ord)

instance Show Ands where
  show as = showL (lits as)
    where showL [] = "1"
          showL ss = concat ss

mapA :: ([Literal] -> [Literal]) -> Ands -> Ands
mapA f (Ands lits) = Ands (f lits)

(&&&) :: Ands -> Ands -> Ands
(Ands []) &&& (Ands []) = Ands []
(Ands lits1) &&& (Ands lits2) = Ands [foldr max "" (lits1 ++ lits2)]

(***) :: [Ands] -> [Ands] -> [Ands]
ands1 *** ands2 = [ and1 &&& and2 | and1 <- ands1, and2 <- ands2 ]

-- Formula [] = False
-- Formula [ Ands [], Ands [a], Ands [b,c] ] = True XOR a XOR (b && c)

newtype Formula = Formula { ands :: [Ands]}
  deriving (Eq,Ord)

instance Show Formula where
  show f = showC (ands f)
    where
      showC [] = "0"
      showC cs = intercalate " + " (map show cs)

mapF :: ([Ands] -> [Ands]) -> Formula -> Formula
mapF f (Formula ands) = Formula (f ands)

mapF2 :: ([Ands] -> [Ands] -> [Ands]) -> Formula -> Formula -> Formula
mapF2 f (Formula ands1) (Formula ands2) = Formula (f ands1 ands2)

(+++) :: Formula -> Formula -> Formula
(Formula ands1) +++ (Formula ands2) = Formula (ands1 ++ ands2)

-- Normalization

-- a && a => a

normalizeLits :: [Literal] -> [Literal]
normalizeLits = map head . group . sort 

-- a XOR a = 0

normalizeAnds :: [Ands] -> [Ands]
normalizeAnds = map head . filter (odd . length) . group . sort

-- Convert to ANF

anf :: Formula -> Formula
anf = mapF (normalizeAnds . map (mapA normalizeLits))

-- 

false :: Formula
false = Formula []

true :: Formula
true = Formula [ Ands [] ]

isStatic :: Formula -> Bool
isStatic f = f == false || f == true

fromBool :: Bool -> Formula
fromBool False = false
fromBool True  = true

toBool :: Formula -> Bool
toBool f | f == false = False
         | f == true  = True
         | otherwise  = error "Internal error: converting a complex formula to bool"

fromVar :: String -> Formula
fromVar s = Formula [ Ands [s] ]

fromVars :: Int -> String -> [Formula]
fromVars n s = map fromVar (zipWith (\ s n -> s ++ show n) (replicate n s) [0..(n-1)])

--

fnot :: Formula -> Formula
fnot form = anf $ true +++ form

fxor :: Formula -> Formula -> Formula
fxor form1 form2 = anf $ form1 +++ form2

fand :: Formula -> Formula -> Formula
fand form1 form2 = anf $ mapF2 (***) form1 form2

--

instance Enum Formula where
  toEnum 0 = false
  toEnum 1 = true
  toEnum _ = error "Internal error: cannot enum symbolic values"
  fromEnum v
    | v == false = 0
    | v == true = 1
    | otherwise = error "Internal error: cannot enum symbolic values"

instance Value Formula where
  zero = false
  one = true
  snot = fnot
  sand = fand
  sxor = fxor

-- PE

peG :: GToffoli s Formula -> ST s ()
peG g@(GToffoli bs cs t) = do
  msg <- showGToffoli g
  traceM (printf "Interpreting %s\n" msg) 
  controls <- mapM readSTRef cs
  tv <- readSTRef t
  let funs = map (\b -> if b then id else fnot) bs
  let r = fxor tv (foldr fand true (zipWith ($) funs controls))
  traceM (printf "\tWriting %s\n" (show r)) 
  writeSTRef t r
  

pe :: OP s Formula -> ST s ()
pe = foldMap peG

run :: Circuit s Formula -> ST s ()
run circ = pe $ S.reverse (op circ)

----------------------------------------------------------------------------------------
-- Tests

-- Retrodictive execution

peExpMod :: Int -> Integer -> Integer -> Integer -> IO ()
peExpMod n a m r = printResult $ runST $ do
  circ <- expm n a m
  mapM_ (uncurry writeSTRef) (zip (ancillaOuts circ) (fromInt (n+1) r))
  mapM_ (uncurry writeSTRef) (zip (xs circ) (fromVars (n+1) "x"))
  run circ
  result <- mapM readSTRef (ancillaIns circ)
  let eqs = zip result (ancillaVals circ)
  return (eqs, showSizes (sizeOP (op circ)))
  where printResult (eqs,size) = do
          putStrLn size
          mapM_ (\(r,v) ->
            let sr = show r
                sv = show v
            in if sr == sv then return () else 
              printf "%s = %s\n" sr sv)
            eqs

retroShor :: Integer -> IO ()
retroShor m = do
      a <- randomRIO (2,m-1)
      let n = ceiling $ logBase 2 (fromInteger m * fromInteger m)
      let gma = gcd m a 
      if gma /= 1 
        then putStrLn (printf "Lucky guess %d = %d * %d\n" m gma (m `div` gma))
        else do putStrLn (printf "n=%d; a=%d\n" n a)
                peExpMod n a m 1

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------
