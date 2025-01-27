{-# LANGUAGE TemplateHaskell #-}

{--

NOTE:

Need bignums

Multiplication of 20 bit numbers already overflows
Subtle distinction between Int (used for indices) and
Integer used for actual values that are added, multiplied, etc.

--}

module ShorPE where

import Data.Char
import GHC.Integer.GMP.Internals
import Data.Vector (Vector, fromList, toList, (!), (//))
import qualified Data.Vector as V 

import Text.Printf
import Test.QuickCheck
import Control.Exception.Assert

--import Debug.Trace

trace :: String -> a -> a
trace s a = a

------------------------------------------------------------------------------
-- Mini reversible language for expmod circuits
-- Syntax

data OP = CX Int Int                       -- if first true; negate second
        | NCX Int Int                      -- if first false; negate second
        | CCX Int Int Int                  -- if first,second true; negate third
        | COP Int OP                       -- if first true; apply op
        | NCOP Int OP                      -- if first false; apply op
        | SWAP Int Int                     -- swap values at given indices
        | (:.:) OP OP                      -- sequential composition
        | ALLOC Int                        -- alloc n bits to front
        | DEALLOC Int                      -- dealloc n bits from front
        | LOOP [Int] (Int -> OP)           -- apply fun to each of indices
        | ASSERT String String (W -> Bool) -- no op; used for debugging

instance Show OP where
  show op = showH "" op
    where
      showH d (CX i j)        = printf "%sCX %d %d" d i j
      showH d (NCX i j)       = printf "%sNCX %d %d" d i j
      showH d (CCX i j k)     = printf "%sCCX %d %d %d" d i j k
      showH d (COP i op)      = printf "%sCOP %d (\n%s)" d i (showH ("  " ++ d) op)
      showH d (NCOP i op)     = printf "%sNCOP %d (\n%s)" d i (showH ("  " ++ d) op)
      showH d (SWAP i j)      = printf "%sSWAP %d %d" d i j
      showH d (op1 :.: op2)   = printf "%s :.:\n%s" (showH d op1) (showH d op2)
      showH d (ALLOC i)       = printf "%sALLOC %d" d i
      showH d (DEALLOC i)     = printf "%sDEALLOC %d" d i
      showH d (LOOP [] f)     = printf ""
      showH d (LOOP [i] f)    = printf "%s" (showH d (f i))
      showH d (LOOP (i:is) f) = printf "%s\n%s" (showH d (f i)) (showH d (LOOP is f))
      showH d (ASSERT s s' f) = printf ""

invert :: OP -> OP
invert (CX i j)         = CX i j
invert (NCX i j)        = NCX i j
invert (CCX i j k)      = CCX i j k
invert (COP i op)       = COP i (invert op)
invert (NCOP i op)      = NCOP i (invert op)
invert (SWAP i j)       = SWAP i j
invert (op1 :.: op2)    = invert op2 :.: invert op1
invert (ALLOC i)        = DEALLOC i
invert (DEALLOC i)      = ALLOC i
invert (LOOP indices f) = LOOP (reverse indices) (\k -> invert (f k))
invert (ASSERT s s' f)  = ASSERT s s' f
       
-- count number of primitive operations

size :: OP -> Int
size (CX i j)         = 1
size (NCX i j)        = 1
size (CCX i j k)      = 1
size (COP i op)       = size op
size (NCOP i op)      = size op
size (SWAP i j)       = 1
size (op1 :.: op2)    = size op1 + size op2
size (ALLOC i)        = 1
size (DEALLOC i)      = 1
size (LOOP indices f) = size (f 0) * length indices
size (ASSERT s s' f)  = 0

------------------------------------------------------------------------------
-- Mini reversible language for expmod circuits
-- Runtime state is a vector of booleans

-- W size vector-of-bits

data W = W Int (Vector Bool)
  deriving Eq

instance Show W where
  show (W n vec) =
    printf "\t[%d] %s" n (concat (V.map (show . fromEnum) vec))

list2W :: [Bool] -> W
list2W bits = W (length bits) (fromList bits)

string2W :: String -> W
string2W bits = list2W (map (toEnum . digitToInt) bits)

toInt :: Vector Bool -> Integer
toInt bs = V.foldr (\b n -> toInteger (fromEnum b) + 2*n) 0 (V.reverse bs)

fromInt :: Int -> Integer -> Vector Bool
fromInt len n = V.replicate (len - length bits) False V.++ fromList bits
  where bin 0 = []
        bin n = let (q,r) = quotRem n 2 in toEnum (fromInteger r) : bin q
        bits = reverse (bin n)

notI :: Vector Bool -> Int -> Vector Bool
notI vec i = vec // [(i , not (vec ! i))]

------------------------------------------------------------------------------
-- Mini reversible language for expmod circuits
-- Interpreter

interp :: OP -> W -> W
interp op w@(W n vec) = 
  case op of                         

    CX i j | vec ! i ->
      assert (j < n) $
      trace (printf "%s\n%s" (show w) (show op)) $
      W n (notI vec j)
    CX _ _ -> w

    NCX i j | not (vec ! i) ->
      assert (j < n) $ 
      trace (printf "%s\n%s" (show w) (show op)) $
      W n (notI vec j)
    NCX _ _ -> w

    CCX i j k | vec ! i && vec ! j -> 
      assert (k < n) $ 
      trace (printf "%s\n%s" (show w) (show op)) $
      W n (notI vec k)
    CCX _ _ _ -> w

    COP i op | vec ! i ->
      interp op w
    COP _ _ -> w

    NCOP i op | not (vec ! i) ->
      interp op w
    NCOP _ _ -> w

    SWAP i j ->
      assert (i < n && j < n) $ 
      trace (printf "%s\n%s" (show w) (show op)) $
      W n (vec // [ (i , vec ! j), (j , (vec ! i)) ])

    op1 :.: op2 -> 
      interp op2 (interp op1 w)

    ALLOC i -> 
      trace (printf "%s\n%s" (show w) (show op)) $
      W (n+i) (V.replicate i False V.++ vec)

    DEALLOC i ->
      assert (n > i) $
      trace (printf "%s\n%s" (show w) (show op)) $
      W (n-i) (V.drop i vec)

    LOOP indices f -> 
      loop indices w
        where loop [] w = w
              loop (i:is) w = loop is (interp (f i) w)

    ASSERT s s' f ->
      assertMessage s s' (assert (f w)) w

------------------------------------------------------------------------------
-- Circuits following Ch.6 of:
-- Quantum Computing: A Gentle Introduction by Rieffel & Polak

-- Simple helpers

-- sum: c, a, b => c, a, (a+b+c) mod 2

sumOP :: Int -> Int -> Int -> OP
sumOP c a b =
  CX a b :.:
  CX c b

t0 = interp (sumOP 0 1 2) (string2W "000") -- 000
t1 = interp (sumOP 0 1 2) (string2W "001") -- 001
t2 = interp (sumOP 0 1 2) (string2W "010") -- 011
t3 = interp (sumOP 0 1 2) (string2W "011") -- 010
t4 = interp (sumOP 0 1 2) (string2W "100") -- 101
t5 = interp (sumOP 0 1 2) (string2W "101") -- 100
t6 = interp (sumOP 0 1 2) (string2W "110") -- 110
t7 = interp (sumOP 0 1 2) (string2W "111") -- 111

prop_sum :: Bool
prop_sum =
  assert (t0 == string2W "000") $
  assert (t1 == string2W "001") $
  assert (t2 == string2W "011") $
  assert (t3 == string2W "010") $
  assert (t4 == string2W "101") $
  assert (t5 == string2W "100") $
  assert (t6 == string2W "110") $
  assert (t7 == string2W "111") $
  True

-- carry: c, a, b, c' => c, a, b, c' xor F(a,b,c)
-- where F(a,b,c) = 1 if two or more inputs are 1

carryOP :: Int -> Int -> Int -> Int -> OP
carryOP c a b c' =
  CCX a b c' :.:
  CX a b :.:
  CCX c b c' :.:
  CX a b

t08 = interp (carryOP 0 1 2 3) (string2W "0000") -- 0000
t09 = interp (carryOP 0 1 2 3) (string2W "0001") -- 0001
t10 = interp (carryOP 0 1 2 3) (string2W "0010") -- 0010
t11 = interp (carryOP 0 1 2 3) (string2W "0011") -- 0011
t12 = interp (carryOP 0 1 2 3) (string2W "0100") -- 0100
t13 = interp (carryOP 0 1 2 3) (string2W "0101") -- 0101
t14 = interp (carryOP 0 1 2 3) (string2W "0110") -- 0111
t15 = interp (carryOP 0 1 2 3) (string2W "0111") -- 0110
t16 = interp (carryOP 0 1 2 3) (string2W "1000") -- 1000
t17 = interp (carryOP 0 1 2 3) (string2W "1001") -- 1001
t18 = interp (carryOP 0 1 2 3) (string2W "1010") -- 1011
t19 = interp (carryOP 0 1 2 3) (string2W "1011") -- 1010
t20 = interp (carryOP 0 1 2 3) (string2W "1100") -- 1101
t21 = interp (carryOP 0 1 2 3) (string2W "1101") -- 1100
t22 = interp (carryOP 0 1 2 3) (string2W "1110") -- 1111
t23 = interp (carryOP 0 1 2 3) (string2W "1111") -- 1110

prop_carry :: Bool
prop_carry =
  assert (t08 == string2W "0000") $
  assert (t09 == string2W "0001") $
  assert (t10 == string2W "0010") $
  assert (t11 == string2W "0011") $
  assert (t12 == string2W "0100") $
  assert (t13 == string2W "0101") $
  assert (t14 == string2W "0111") $
  assert (t15 == string2W "0110") $
  assert (t16 == string2W "1000") $
  assert (t17 == string2W "1001") $
  assert (t18 == string2W "1011") $
  assert (t19 == string2W "1010") $
  assert (t20 == string2W "1101") $
  assert (t21 == string2W "1100") $
  assert (t22 == string2W "1111") $
  assert (t23 == string2W "1110") $
  True

-- takes n-bits [a, b, c, ... , y, z] stored in the range (i,e)
-- and produces [b, c, ... , y, z, a]
--
-- when a=0, this is multiplication by 2

shiftOP :: (Int,Int) -> OP
shiftOP (i,e) =
  LOOP [i..(e-1)] (\k -> SWAP k (k+1))

shiftOPGuard :: (Int,Int) -> OP
shiftOPGuard (i,e) =
  ASSERT "shiftOP" "Precondition wn >= n failed"
    (\w@(W wn vec) -> wn >= e-i+1) :.:
  ASSERT "shiftOP" "Precondition x[n] == 0 failed"
    (\w@(W wn vec) -> vec ! i == False) :.:
  shiftOP (i,e)

unShiftOPGuard :: (Int,Int) -> OP
unShiftOPGuard (i,e) =
  ASSERT "unShiftOP" "Precondition wn >= n failed"
    (\w@(W wn vec) -> wn >= e-i+1) :.:
  invert (shiftOP (i,e)) :.:
  ASSERT "unShiftOP" "Postcondition x[n] == 0 failed"
    (\w@(W wn vec) -> vec ! i == False)

prop_shift :: Property
prop_shift = forAll
  (do n <- chooseInt (1,100)
      xs <- vector n
      return (W (n+1) (fromList (False : xs))))
  (\ w@(W wn vec) ->
    let actual = interp (shiftOPGuard (0,wn-1)) w
        res = 2 * toInt vec
        expected = W wn (fromInt wn res)
    in actual === expected)

-- a has n-bits stored in the range (ai,ae)
-- b has n-bits stored in the range (bi,be)

-- copy: a , b => a, a XOR b

copyOP :: Int -> (Int,Int) -> (Int,Int) -> OP
copyOP n (ai,ae) (bi,be) =
  LOOP [0..(n-1)] (\k -> CX (ai+k) (bi+k))

copyOPGuard :: Int -> (Int,Int) -> (Int,Int) -> OP
copyOPGuard n (ai,ae) (bi,be) =
  ASSERT "copyOP" "Precondition wn >= 2n failed"
    (\w@(W wn vec) -> wn >= 2*n) :.:
  copyOP n (ai,ae) (bi,be)

unCopyOPGuard :: Int -> (Int,Int) -> (Int,Int) -> OP
unCopyOPGuard n (ai,ae) (bi,be) =
  ASSERT "unCopyOP" "Precondition wn >= 2n failed"
    (\w@(W wn vec) -> wn >= 2*n) :.:
  invert (copyOP n (ai,ae) (bi,be))

prop_copy :: Property
prop_copy = forAll
  (do n <- chooseInt (1,100)
      as <- vector n
      let bs = replicate n False
      return (W (2*n) (fromList (as ++ bs))))
  (\ w@(W wn vec) ->
    let n = wn `div` 2
        actual = interp (copyOPGuard n (0,n-1) (n,2*n-1)) w
        (as,bs) = V.splitAt n vec
        expected = W wn (as V.++ (V.zipWith (/=) as bs))
    in actual === expected)

------------------------------------------------------------------------------
-- Addition of n-bit numbers

-- c has n-bits stored in the range (ci,ce) inclusive
--   initialized to 0
-- a has n-bits stored in the range (ai,ae)
-- b has (n+1)-bits stored in the range (bi,be)

-- add:  0, a, b => 0, a, (a + b) `mod` (2 ^ (n+1))
-- unAdd:  0, a, b => 0, a, (b - a) (+ 2 ^ (n+1) if (b-a) negative)

addOP :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
addOP n (ci,ce) (ai,ae) (bi,be)
  | n == 1 =
    carryOP ci ai be bi :.:
    sumOP ci ai be
  | otherwise =
    carryOP ce ae be (ce-1) :.:
    addOP (n-1) (ci,ce-1) (ai,ae-1) (bi,be-1) :.:
    invert (carryOP ce ae be (ce-1)) :.:
    sumOP ce ae be

-- Assertions and testing

addOPGuard :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
addOPGuard n (ci,ce) (ai,ae) (bi,be) =
  assert ((ce-ci) == (n-1) && (ae-ai) == (n-1) && (be-bi) == n) $ 
  ASSERT "addOP" "Precondition wn >= 3n+1 failed"
    (\ (W wn _) -> wn >= 3*n + 1) :.:
  ASSERT "addOP" "Precondition c == 0 failed'"
    (\ (W _ vec) -> toInt (V.slice ci n vec) == 0) :.:
  addOP n (ci,ce) (ai,ae) (bi,be) :.:
  ASSERT "addOP" "Postcondition c == 0 failed"
    (\ (W _ vec) -> toInt (V.slice ci n vec) == 0)

unAddOPGuard :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
unAddOPGuard n (ci,ce) (ai,ae) (bi,be) =
  assert ((ce-ci) == (n-1) && (ae-ai) == (n-1) && (be-bi) == n) $ 
  ASSERT "unAddOP" "Precondition wn >= 3n+1 failed"
    (\ (W wn _) -> wn >= 3*n + 1) :.:
  ASSERT "unAddOP" "Precondition c == 0 failed'"
    (\ (W _ vec) -> toInt (V.slice ci n vec) == 0) :.:
  invert (addOP n (ci,ce) (ai,ae) (bi,be)) :.:
  ASSERT "unAddOP" "Postcondition c == 0 failed"
    (\ (W _ vec) -> toInt (V.slice ci n vec) == 0)

addGen :: Gen W
addGen =
  do n <- chooseInt (1, 100)
     let wn = 3 * n + 1
     let cs = replicate n False
     as <- vector n
     bs <- vector (n+1)
     return (W wn (fromList (cs ++ as ++ bs)))

prop_add :: Property
prop_add = forAll addGen $ \ w@(W wn vec) ->
  let n = (wn - 1) `div` 3
      actual = interp (addOPGuard n (0,n-1) (n,2*n-1) (2*n,3*n)) w
      (cs,r) = V.splitAt n vec
      (as,bs) = V.splitAt n r
      sum = (toInt as + toInt bs) `mod` (2 ^ (n+1))
      sums = fromInt (n+1) sum
      expected = W wn (cs V.++ as V.++ sums)
  in actual === expected

prop_unAdd :: Property
prop_unAdd = forAll addGen $ \ w@(W wn vec) ->
  let n = (wn - 1) `div` 3
      actual = interp (unAddOPGuard n (0,n-1) (n,2*n-1) (2*n,3*n)) w
      (cs,r) = V.splitAt n vec
      (as,bs) = V.splitAt n r
      diff = toInt bs - toInt as
      diffs = fromInt (n+1) (if diff < 0 then diff + 2 ^ (n+1) else diff)
      expected = W wn (cs V.++ as V.++ diffs)
  in actual === expected

------------------------------------------------------------------------------
-- Addition of n-bit numbers modulo another n-bit number

-- a has n-bits stored in the range (ai,ae)
-- b has (n+1)-bits stored in the range (bi,be)
-- m has n-bits stored in the range (mi,me)
-- precondition: a < m and b < m and m > 0 to make sense of mod

-- addMod: a, b, m => a, (a+b) `mod` m, m
-- unAddMod: a, b, m => a, (b-a)*, m where we add m to (b-a) if negative

addModOP :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
addModOP n (ai,ae) (bi,be) (mi,me) = 
  ALLOC n :.: -- carry
  ALLOC 1 :.: -- t
  addOPGuard n (1,n) (ai+n+1,ae+n+1) (bi+n+1,be+n+1) :.:
  unAddOPGuard n (1,n) (mi+n+1,me+n+1) (bi+n+1,be+n+1) :.:
  CX (bi+n+1) 0 :.:
  COP 0 (addOPGuard n (1,n) (mi+n+1,me+n+1) (bi+n+1,be+n+1)) :.:
  unAddOPGuard n (1,n) (ai+n+1,ae+n+1) (bi+n+1,be+n+1) :.:
  NCX (bi+n+1) 0 :.:
  addOPGuard n (1,n) (ai+n+1,ae+n+1) (bi+n+1,be+n+1) :.:
  ASSERT "addModOP" "Failed to restore t to 0"
    (\ (W _ vec) -> vec ! 0 == False) :.:
  DEALLOC 1 :.:
  ASSERT "addModOP" "Failed to restore carry to 0"
    (\ (W _ vec) -> toInt (V.slice 0 n vec) == 0) :.:
  DEALLOC n

-- Assertions and testing

addModOPGuard :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
addModOPGuard n (ai,ae) (bi,be) (mi,me) = 
  assert ((ae-ai) == (n-1) && (be-bi) == n && (me-mi) == (n-1)) $ 
  ASSERT "addModOP" "Precondition wn >= 3n+1 failed"
    (\ (W wn _) -> wn >= 3*n + 1) :.:
  ASSERT "addModOP" "Precondition a < m failed'"
    (\ (W _ vec) -> toInt (V.slice ai n vec) < toInt (V.slice mi n vec)) :.:
  ASSERT "addModOP" "Precondition b < m failed'"
    (\ (W _ vec) -> toInt (V.slice bi n vec) < toInt (V.slice mi n vec)) :.:
  addModOP n (ai,ae) (bi,be) (mi,me) 

unAddModOPGuard :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
unAddModOPGuard n (ai,ae) (bi,be) (mi,me) = 
  assert ((ae-ai) == (n-1) && (be-bi) == n && (me-mi) == (n-1)) $ 
  ASSERT "unAddModOP" "Precondition wn >= 3n+1 failed"
    (\ (W wn _) -> wn >= 3*n + 1) :.:
  ASSERT "unAddModOP" "Precondition a < m failed'"
    (\ (W _ vec) -> toInt (V.slice ai n vec) < toInt (V.slice mi n vec)) :.:
  ASSERT "unAddModOP" "Precondition b < m failed'"
    (\ (W _ vec) -> toInt (V.slice bi n vec) < toInt (V.slice mi n vec)) :.:
  invert (addModOP n (ai,ae) (bi,be) (mi,me))

addModGen :: Gen W
addModGen =
  do n <- chooseInt (1, 100)
     let wn = 3 * n + 1
     m <- chooseInteger (1, 2^n-1)
     a <- chooseInteger (0,m-1)
     b <- chooseInteger (0,m-1)
     return (W wn (fromInt n a V.++ fromInt (n+1) b V.++ fromInt n m))

prop_addMod :: Property
prop_addMod = forAll addModGen $ \ w@(W wn vec) ->
  let n = (wn - 1) `div` 3
      actual = interp (addModOPGuard n (0,n-1) (n,2*n) (2*n+1,3*n)) w
      (as,r) = V.splitAt n vec
      (bs,ms) = V.splitAt (n+1) r
      a = toInt as
      b = toInt bs
      m = toInt ms
      sum = (a + b) `mod` m
      expected = W wn (as V.++ fromInt (n+1) sum V.++ ms)
  in actual === expected

prop_unAddMod :: Property
prop_unAddMod = forAll addModGen $ \ w@(W wn vec) ->
  let n = (wn - 1) `div` 3
      actual = interp (unAddModOPGuard n (0,n-1) (n,2*n) (2*n+1,3*n)) w
      (as,r) = V.splitAt n vec
      (bs,ms) = V.splitAt (n+1) r
      a = toInt as
      b = toInt bs
      m = toInt ms
      diff = b - a
      diffs = fromInt (n+1) (if diff < 0 then diff + m else diff)
      expected = W wn (as V.++ diffs V.++ ms)
  in actual === expected

------------------------------------------------------------------------------
-- Multiply two n-bit numbers mod another n-bit number

-- a has (n+1)-bits stored in the range (ai,ae)
-- b has (n+1)-bits stored in the range (bi,be)
-- m has n-bits stored in the range (mi,me)
-- p has (n+1)-bits stored in the range (pi,pe)
-- precondition: a < m, p < m, and m > 0 to make sense of mod

-- timesMod: a, b, m, p => a, b, m, (p + ab) `mod` m
-- unTimesMod: a, b, m, p => a, b, m, (p - ab `mod` m) (add m if negative)

timesModOP :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
timesModOP n (ai,ae) (bi,be) (mi,me) (pi,pe) =
  ALLOC n :.: -- carry
  ALLOC (n+1) :.: -- t
  LOOP [0..n] (\i ->
    unAddOPGuard n (n+1,2*n) (mi+d,me+d) (ai+d,ae+d) :.:
    CX (ai+d) i :.:
    COP i (addOPGuard n (n+1,2*n) (mi+d,me+d) (ai+d,ae+d)) :.: 
    COP (be+d-i) (addModOPGuard n (ai+d+1,ae+d) (pi+d,pe+d) (mi+d,me+d)) :.: 
    shiftOPGuard (ai+d,ae+d) 
  ) :.:
  LOOP [n,(n-1)..0] (\i ->
    unShiftOPGuard (ai+d,ae+d) :.:
    COP i (unAddOPGuard n (n+1,2*n) (mi+d,me+d) (ai+d,ae+d)) :.: 
    CX (ai+d) i :.:
    addOPGuard n (n+1,2*n) (mi+d,me+d) (ai+d,ae+d)
  ) :.:
  ASSERT "timesModOP" "Failed to restore temporary register to 0"
    (\ (W _ vec) -> toInt (V.slice 0 (n+1) vec) == 0) :.:
  DEALLOC (n+1) :.:
  ASSERT "timesModOP" "Failed to restore carry to 0"
    (\ (W _ vec) -> toInt (V.slice 0 n vec) == 0) :.:
  DEALLOC n
  where d = 2 * n + 1

timesModOPGuard :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
timesModOPGuard n (ai,ae) (bi,be) (mi,me) (pi,pe) =
  assert ((ae-ai) == n && (be-bi) == n && (me-mi) == n-1 && (pe-pi) == n) $
  ASSERT "timesModOP" "Precondition wn >= 4n+3 failed"
    (\ w@(W wn _) -> wn >= 4 * n + 3) :.:
  ASSERT "timesModOP" "Precondition a < m failed'"
    (\ (W _ vec) -> toInt (V.slice ai n vec) < toInt (V.slice mi n vec)) :.:
  ASSERT "timesModOP" "Precondition p < m failed'"
    (\ (W _ vec) -> toInt (V.slice pi n vec) < toInt (V.slice mi n vec)) :.:
  timesModOP n (ai,ae) (bi,be) (mi,me) (pi,pe)

unTimesModOPGuard :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
unTimesModOPGuard n (ai,ae) (bi,be) (mi,me) (pi,pe) =
  assert ((ae-ai) == n && (be-bi) == n && (me-mi) == n-1 && (pe-pi) == n) $
  ASSERT "unTimesModOP" "Precondition wn >= 4n+3 failed"
    (\ w@(W wn _) -> wn >= 4 * n + 3) :.:
  ASSERT "unTimesModOP" "Precondition a < m failed'"
    (\ (W _ vec) -> toInt (V.slice ai n vec) < toInt (V.slice mi n vec)) :.:
  ASSERT "unTimesModOP" "Precondition p < m failed'"
    (\ (W _ vec) -> toInt (V.slice pi n vec) < toInt (V.slice mi n vec)) :.:
  invert (timesModOP n (ai,ae) (bi,be) (mi,me) (pi,pe))

timesModGen :: Gen W
timesModGen =
  do n <- chooseInt (1, 100)
     let wn = 4 * n + 3
     m <- chooseInteger (1, 2 ^ n - 1)
     a <- chooseInteger (0, m - 1)
     b <- chooseInteger (0, 2 ^ (n+1) - 1)
     p <- chooseInteger (0, m - 1)
     return (W wn (fromInt (n+1) a V.++ fromInt (n+1) b
                   V.++ fromInt n m V.++ fromInt (n+1) p))

prop_timesMod :: Property
prop_timesMod = forAll timesModGen $ \ w@(W wn vec) ->
  let n = (wn - 3) `div` 4
      actual = interp (timesModOPGuard n (0,n) (n+1,2*n+1) (2*n+2,3*n+1) (3*n+2,4*n+2)) w
      (as,r) = V.splitAt (n+1) vec
      (bs,r') = V.splitAt (n+1) r
      (ms,ps) = V.splitAt n r'
      a = toInt as
      b = toInt bs
      m = toInt ms
      p = toInt ps
      prod = (p + a * b) `mod` m
      prods = fromInt (n+1) prod
      expected = W wn (as V.++ bs V.++ ms V.++ prods)
  in actual === expected

prop_unTimesMod :: Property
prop_unTimesMod = forAll timesModGen $ \ w@(W wn vec) ->
  let n = (wn - 3) `div` 4
      actual = interp (unTimesModOPGuard n (0,n) (n+1,2*n+1) (2*n+2,3*n+1) (3*n+2,4*n+2)) w
      (as,r) = V.splitAt (n+1) vec
      (bs,r') = V.splitAt (n+1) r
      (ms,ps) = V.splitAt n r'
      a = toInt as
      b = toInt bs
      m = toInt ms
      p = toInt ps
      pres = p - ((a * b) `mod` m)
      quot = if (pres < 0) then pres + m else pres
      quots = fromInt (n+1) quot
      expected = W wn (as V.++ bs V.++ ms V.++ quots)
  in actual === expected

------------------------------------------------------------------------------
-- Square mod n
-- Special case of multiplication

-- a has (n+1)-bits stored in the range (ai,ae)
-- m has n-bits stored in the range (mi,me)
-- s has (n+1)-bits stored in the range (si,se)
-- precondition: a < m, s < m, and m > 0 to make sense of mod

-- squareMod: a, m, s => a, m, (s + a^2) `mod` m
-- unSquareMod: a, m, s => a, m, (s - a^2 `mod` m) (add m if negative)

squareModOP :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
squareModOP n (ai,ae) (mi,me) (si,se) =
  ALLOC (n+1) :.: -- t
  copyOPGuard (n+1) (ai+d,ae+d) (0,n) :.:
  timesModOPGuard n (ai+d,ae+d) (0,n) (mi+d,me+d) (si+d,se+d) :.:
  unCopyOPGuard (n+1) (ai+d,ae+d) (0,n) :.:
  ASSERT "squareModOP" "Failed to restore temporary register to 0"
    (\ (W _ vec) -> toInt (V.slice 0 (n+1) vec) == 0) :.:
  DEALLOC (n+1)
  where d = n + 1

unSquareModOP :: Int -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
unSquareModOP n (ai,ae) (mi,me) (si,se) =
  invert (squareModOP n (ai,ae) (mi,me) (si,se)) 

squareModGen :: Gen W
squareModGen =
  do n <- chooseInt (1, 100)
     let wn = 3 * n + 2
     m <- chooseInteger (1, 2 ^ n - 1)
     a <- chooseInteger (0, m - 1)
     s <- chooseInteger (0, m - 1)
     return (W wn (fromInt (n+1) a V.++ fromInt n m V.++ fromInt (n+1) s))

prop_squareMod :: Property
prop_squareMod = forAll squareModGen $ \ w@(W wn vec) ->
  let n = (wn - 2) `div` 3
      actual = interp (squareModOP n (0,n) (n+1,2*n) (2*n+1,3*n+1)) w
      (as,r) = V.splitAt (n+1) vec
      (ms,ss) = V.splitAt n r
      a = toInt as
      m = toInt ms
      s = toInt ss
      prod = (s + a * a) `mod` m
      prods = fromInt (n+1) prod
      expected = W wn (as V.++ ms V.++ prods)
  in actual === expected

prop_unSquareMod :: Property
prop_unSquareMod = forAll squareModGen $ \ w@(W wn vec) ->
  let n = (wn - 2) `div` 3
      actual = interp (invert (squareModOP n (0,n) (n+1,2*n) (2*n+1,3*n+1))) w
      (as,r) = V.splitAt (n+1) vec
      (ms,ss) = V.splitAt n r
      a = toInt as
      m = toInt ms
      s = toInt ss
      pres = s - ((a * a) `mod` m)
      quot = if (pres < 0) then pres + m else pres
      quots = fromInt (n+1) quot
      expected = W wn (as V.++ ms V.++ quots)
  in actual === expected

------------------------------------------------------------------------------
-- ExpMod mod n

-- a has (n+1)-bits stored in the range (ai,ae)
-- b has n-bits stored in the range (bi,be)
-- m has n-bits stored in the range (mi,me)
-- p has (n+1)-bits stored in the range (pi,pe)
-- e has (n+1)-bits stored in the range (ei,ee)
-- precondition: 0 < a < m, p < m, e < m, and m > 1

-- expMod : a, b, m, p, e => a, b, m, p, e XOR p(a^b) `mod` m
-- unExpMod : a, b, m, p, e => a, b, m, 1, e XOR p(a^b) `mod` m

expModOP :: Int -> Int ->
            (Int,Int) -> (Int,Int) -> (Int,Int) -> (Int,Int) -> (Int,Int) -> OP
expModOP n k (ai,ae) (bi,be) (mi,me) (pi,pe) (ei,ee)
  | k == 1 =
--    NCOP bi (copyOPGuard (n+1) (pi,pe) (ei,ee)) :.:
--    NCOP bi (addModOPGuard
    COP bi (timesModOPGuard n (ai,ae) (pi,pe) (mi,me) (ei,ee)) 
  | otherwise =
    ALLOC (n+1) :.: -- v
    ALLOC (n+1) :.: -- u
    NCOP (be+d) (copyOPGuard (n+1) (pi+d,pe+d) (n+1,2*n+1)) :.:
    COP (be+d) (timesModOPGuard n (ai+d,ae+d) (pi+d,pe+d) (mi+d,me+d) (ei+d,ee+d)) :.:
    squareModOP n (ai+d,ae+d) (mi+d,me+d) (0,n) :.:
    expModOP n (k-1) (0,n) (bi+d,be+d-1) (mi+d,me+d) (n+1,2*n+1) (ei+d,ee+d) :.:
    unSquareModOP n (ai+d,ae+d) (mi+d,me+d) (0,n) :.:
--    COP (be+d) (unTimesModOPGuard n (ai+d,ae+d) (pi+d,pe+d) (mi+d,me+d) (ei+d,ee+d)) :.:
    NCOP (be+d) (unCopyOPGuard (n+1) (pi+d,pe+d) (n+1,2*n+1)) :.:
    DEALLOC (n+1) :.: 
    DEALLOC (n+1) 
    where d = 2*n + 2



{--

expModGen :: Gen W
expModGen =
  do n <- chooseInt (2, 2)
     let wn = 5 * n + 3
     m <- chooseInteger (2, 2 ^ n - 1)
     a <- chooseInteger (1, m - 1)
     b <- chooseInteger (0, 2 ^ n - 1)
     p <- chooseInteger (0, m - 1)
     e <- chooseInteger (0, m - 1)
     return (W wn (fromInt (n+1) a V.++ fromInt n b V.++ fromInt n m V.++ 
                    fromInt (n+1) p V.++ fromInt (n+1) e))

--expModGen = return (string2W "0010110001000")

prop_expMod :: Property
prop_expMod = forAll expModGen $ \ w@(W wn vec) ->
  let n = (wn - 3) `div` 5
      actual = interp
                 (expModOP n n
                  (0,n) (n+1,2*n) (2*n+1,3*n) (3*n+1,4*n+1) (4*n+2,5*n+2))
               w
      (as,r) = V.splitAt (n+1) vec
      (bs,r') = V.splitAt n r
      (ms,r'') = V.splitAt n r'
      (ps,es) = V.splitAt (n+1) r''
      a = toInt as
      b = toInt bs
      m = toInt ms
      p = toInt ps
      e = toInt es
      res = (e + p * powModInteger a b m) `mod` m
      expected = W wn (as V.++ bs V.++ ms V.++ ps V.++ fromInt (n+1) res)
  in actual === expected 

--}

-------------------------------------------------------------------------------
-- Run all tests

return []                  -- ... weird TH hack !!!
checks = $quickCheckAll

------------------------------------------------------------------------------
------------------------------------------------------------------------------
