module OaDaFit.LeastSquares
  ( leastSquares
  , solveLinear
  ) where

import Data.List (transpose)

-- | Ordinary least squares via the normal equations (XᵀX)β = Xᵀy.
-- Rows are observations, each a list of feature values (columns); ys are the
-- targets. Returns one coefficient per column, or Nothing if singular.
leastSquares :: [[Double]] -> [Double] -> Maybe [Double]
leastSquares rows ys = solveLinear xtx xty
  where
    cols = transpose rows           -- one list per feature
    xtx = [[dot a b | b <- cols] | a <- cols]
    xty = [dot a ys | a <- cols]
    dot u v = sum (zipWith (*) u v)

-- | Solve A x = b for a square A via Gaussian elimination with partial
-- pivoting. Returns Nothing if A is singular (pivot ~ 0).
solveLinear :: [[Double]] -> [Double] -> Maybe [Double]
solveLinear a b = go (zipWith (\row bi -> row ++ [bi]) a b)
  where
    n = length b
    go rows = eliminate 0 rows

    eliminate i rows
      | i >= n = Just (backSub rows)
      | otherwise =
          case pivotAt i rows of
            Nothing -> Nothing
            Just rows' ->
              let piv = rows' !! i
                  pivVal = piv !! i
                  reduce r
                    | otherwise =
                        let f = (r !! i) / pivVal
                         in zipWith (\rv pv -> rv - f * pv) r piv
                  rows'' =
                    [ if j == i then piv else reduce (rows' !! j)
                    | j <- [0 .. n - 1]
                    ]
               in eliminate (i + 1) rows''

    -- move a row with a non-negligible pivot in column i into position i
    pivotAt i rows =
      let (before, rest) = splitAt i rows
       in case break (\r -> abs (r !! i) > 1e-9) rest of
            (_, []) -> Nothing
            (skipped, chosen : others) ->
              Just (before ++ chosen : skipped ++ others)

    backSub rows = reverse (foldl step [] [n - 1, n - 2 .. 0])
      where
        step solvedDesc i =
          -- solvedDesc holds x[i+1..n-1] in descending-index order
          let row = rows !! i
              rhs = row !! n
              higher = zip [n - 1, n - 2 ..] solvedDesc
              known = sum [ (row !! j) * xj | (j, xj) <- higher ]
              xi = (rhs - known) / (row !! i)
           in solvedDesc ++ [xi]
