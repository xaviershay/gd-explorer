module OaDaFit.InputsSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.List (find)
import OaDaFit.Inputs (Inputs (..), characterHealth, characterInputs, loadInputs)
import GrimDawn.Gdc (Character (..))

spec :: Spec
spec = describe "characterInputs" $ do
  it "extracts Shield's geared level and attributes matching the app" $ do
    (db, chars) <- loadInputs "data/gd-data"
    case find ((== T.pack "Shield") . charName) chars of
      Nothing -> expectationFailure "no character named Shield"
      Just c -> do
        let g = characterInputs db c True
        inLevel g `shouldBe` 100
        -- Current values verified against `gd-explorer character Shield
        -- --buffs permanent`: Cunning 606, Physique 1432. (Smoke test against
        -- the real save in data/gd-data; will differ for other users' saves.)
        round (inCun g) `shouldBe` (606 :: Int)
        round (inPhys g) `shouldBe` (1432 :: Int)
  it "ungeared Cunning is no greater than geared Cunning" $ do
    (db, chars) <- loadInputs "data/gd-data"
    case find ((== T.pack "Shield") . charName) chars of
      Just c ->
        inCun (characterInputs db c False) <= inCun (characterInputs db c True)
          `shouldBe` True
      Nothing -> expectationFailure "no Shield"
  it "characterHealth is positive and no less geared than ungeared" $ do
    (db, chars) <- loadInputs "data/gd-data"
    case find ((== T.pack "Shield") . charName) chars of
      Just c -> do
        let ungeared = characterHealth db c False
            geared = characterHealth db c True
        ungeared `shouldSatisfy` (> 0)
        geared `shouldSatisfy` (>= ungeared)
      Nothing -> expectationFailure "no Shield"
