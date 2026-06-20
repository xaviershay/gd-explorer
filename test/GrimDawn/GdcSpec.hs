module GrimDawn.GdcSpec (spec) where

import qualified Data.Text as T
import GrimDawn.Gdc
import Test.Hspec

spec :: Spec
spec =
  describe "loadCharacterFile (Odie.gdc fixture)" $ do
    it "parses the whole file (all block checksums verify, EOF reached)" $ do
      r <- loadCharacterFile "test/fixtures/Odie.gdc"
      case r of
        Left e -> expectationFailure ("parse failed: " ++ e)
        Right _ -> pure ()

    it "reads the expected header fields" $ do
      Right c <- loadCharacterFile "test/fixtures/Odie.gdc"
      charName c `shouldBe` "Odie"
      charLevel c `shouldBe` 65
      charHardcore c `shouldBe` False

    it "reads stable item counts" $ do
      Right c <- loadCharacterFile "test/fixtures/Odie.gdc"
      length (charEquipped c) `shouldBe` 15
      length (charInventory c) `shouldBe` 162
      length (charPersonalStash c) `shouldBe` 150

    it "item basenames look like database record paths" $ do
      Right c <- loadCharacterFile "test/fixtures/Odie.gdc"
      let names = map itemBaseName (charEquipped c ++ charInventory c)
      all (T.isPrefixOf "records/") names `shouldBe` True
