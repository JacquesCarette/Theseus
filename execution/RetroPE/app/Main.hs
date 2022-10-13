module Main where

import System.TimeIt
import Text.Printf

import RunQAlgos (runRetroGrover', runRetroShor)

------------------------------------------------------------------------------

main :: IO ()
main = do
  -- runRetroShor (Just 40) Nothing Nothing 21
  -- should be fast: 15, 51, 83, 771; slower: 21, 35
  -- runRetroShor (Just 42) 15 1
  -- mapM_ (retroGrover 5) [0..31]
  -- runRetroGrover' 23 0
  mapM_ grover [0..28]
  where
    grover n = do
      printf "n = %d\t" n
      timeIt (runRetroGrover' n (min 10 (2^n - 1)))

-- Notes for RetroShor:
-- For 21, 41 and 42 (as seeds) are lucky guesses; 40 'works'
-- For 15 and 51, 42 is not a lucky guess

------------------------------------------------------------------------------
