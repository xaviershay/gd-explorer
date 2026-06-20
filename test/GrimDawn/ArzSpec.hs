module GrimDawn.ArzSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import GrimDawn.Arz
import Test.Hspec
import TestHelpers (gamePath, withDataFile)

spec :: Spec
spec = do
  describe "mergeDbs" $
    it "lets later databases win on key collision" $ do
      let base = HM.fromList [("r", HM.fromList [("Class", VString "old")])]
          dlc = HM.fromList [("r", HM.fromList [("Class", VString "new")])]
          merged = mergeDbs [base, dlc]
      (HM.lookup "r" merged >>= HM.lookup "Class") `shouldBe` Just (VString "new")

  describe "value accessors" $ do
    it "valueInt / valueFloat / valueText" $ do
      valueInt (VInt 7) `shouldBe` Just 7
      valueFloat (VInt 7) `shouldBe` Just 7.0
      valueFloat (VFloat 1.5) `shouldBe` Just 1.5
      valueText (VString "x") `shouldBe` Just "x"

  describe "loadArz (real database.arz)" $ do
    it "loads a non-trivial number of item records" $
      withDataFile (gamePath "database/database.arz") $ \fp -> do
        raw <- BS.readFile fp
        case loadArz HM.empty raw of
          Left e -> expectationFailure e
          Right db -> HM.size db > 1000 `shouldBe` True

    it "resolves a known base-game item record with expected fields" $
      withDataFile (gamePath "database/database.arz") $ \fp -> do
        raw <- BS.readFile fp
        let Right db = loadArz HM.empty raw
            rec_ = HM.lookup "records/items/gearhead/b005_head.dbr" db
        (rec_ >>= lookupField "Class") `shouldBe` Just (VString "ArmorProtective_Head")
        case rec_ >>= lookupField "levelRequirement" of
          Just v -> valueInt v `shouldBe` Just 18
          Nothing -> expectationFailure "missing levelRequirement"
        -- every key resolves to *some* value
        case rec_ of
          Just r -> all (not . T.null) (HM.keys r) `shouldBe` True
          Nothing -> expectationFailure "record not found"
