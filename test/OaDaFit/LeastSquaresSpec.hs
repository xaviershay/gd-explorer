module OaDaFit.LeastSquaresSpec (spec) where

import Test.Hspec
import OaDaFit.LeastSquares (leastSquares)

spec :: Spec
spec = describe "leastSquares" $ do
  it "recovers exact coefficients for a consistent system" $ do
    -- y = 2 + 3*x ; columns are [1, x]
    let rows = [[1, 0], [1, 1], [1, 2], [1, 5]]
        ys   = [2, 5, 8, 17]
    case leastSquares rows ys of
      Just [b, k] -> do
        abs (b - 2) < 1e-9 `shouldBe` True
        abs (k - 3) < 1e-9 `shouldBe` True
      other -> expectationFailure ("expected [2,3], got " ++ show other)
  it "returns Nothing for a singular system" $
    -- two identical columns -> XtX singular
    leastSquares [[1, 1], [1, 1], [1, 1]] [1, 1, 1] `shouldBe` Nothing
