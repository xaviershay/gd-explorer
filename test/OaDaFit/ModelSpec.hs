module OaDaFit.ModelSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import OaDaFit.Inputs (Inputs (..))
import OaDaFit.Model

-- an Inputs with everything zero except the fields a test sets
zeroInputs :: Inputs
zeroInputs = Inputs (T.pack "x") True 0 0 0 0 0 0 0 0 0

spec :: Spec
spec = describe "fitCandidate" $ do
  it "recovers a known OA law: OA = 100 + 10*level + 0.4*cunning" $ do
    let mk lvl cun =
          let i = zeroInputs { inLevel = lvl, inCun = cun }
           in Point i (100 + 10 * lvl + 0.4 * cun)
        pts = [ mk 10 50, mk 50 200, mk 100 400, mk 25 600, mk 80 300 ]
        cand = Candidate "b+k*lvl+a*cun" Free Free Free (Fixed 0)
    case fitCandidate OA pts cand of
      Just fr -> do
        abs (frBase fr - 100) < 1e-6 `shouldBe` True
        abs (frLevel fr - 10) < 1e-6 `shouldBe` True
        abs (frAttr fr - 0.4) < 1e-6 `shouldBe` True
        frRms fr < 1e-6 `shouldBe` True
      Nothing -> expectationFailure "fit failed"
  it "applies the percent modifier outside the linear part" $ do
    -- observed = (base+...) * (1 + pct/100); with pct=10 the fit must undo it
    let i = zeroInputs { inLevel = 10, inPctOA = 10 }
        pts = [ Point i (110 * 1.10) -- base 10 + 10*lvl(=100) = 110, *1.1
              , Point (zeroInputs { inLevel = 20 }) 210 ]
        cand = Candidate "b+k*lvl" Free Free (Fixed 0) (Fixed 0)
    case fitCandidate OA pts cand of
      Just fr -> abs (frBase fr - 10) < 1e-6 `shouldBe` True
      Nothing -> expectationFailure "fit failed"
