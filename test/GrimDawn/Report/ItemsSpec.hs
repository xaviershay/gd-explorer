module GrimDawn.Report.ItemsSpec (spec) where

import qualified Data.Set as Set
import GrimDawn.Aggregate (Location (..), loadOwnedItems)
import GrimDawn.Db (loadGameDb)
import GrimDawn.Item (ItemAttrs (..))
import GrimDawn.Report.Items
import Test.Hspec
import TestHelpers (dataDir, gamePath, withDataFile)

-- a legendary fire-resist helm equipped by "Odie"
helmAttrs :: ItemAttrs
helmAttrs =
  ItemAttrs
    { iaDisplayName = "Test Helm"
    , iaClass = Just "ArmorProtective_Head"
    , iaType = Just "head"
    , iaClassification = Just "Legendary"
    , iaLevelRequirement = Just 65
    , iaResists = Set.fromList ["fire", "cold"]
    , iaDamage = Set.empty
    , iaIsSet = False
    , iaSetRecord = Nothing
    }

loc :: Location
loc = Equipped "Odie"

spec :: Spec
spec = do
  describe "matchesFilter predicates (synthetic)" $ do
    it "matches type via synonym (helm -> head)" $ do
      matchesFilter emptyFilter {ifType = Just "helm"} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifType = Just "ring"} helmAttrs loc `shouldBe` False
    it "requires all requested resistances" $ do
      matchesFilter emptyFilter {ifResists = ["fire"]} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifResists = ["fire", "cold"]} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifResists = ["poison"]} helmAttrs loc `shouldBe` False
    it "filters by damage type" $
      matchesFilter emptyFilter {ifDamage = ["fire"]} helmAttrs loc `shouldBe` False
    it "filters by level bounds" $ do
      matchesFilter emptyFilter {ifMinLevel = Just 70} helmAttrs loc `shouldBe` False
      matchesFilter emptyFilter {ifMinLevel = Just 60, ifMaxLevel = Just 70} helmAttrs loc
        `shouldBe` True
    it "filters by character (location substring)" $ do
      matchesFilter emptyFilter {ifChar = Just "odie"} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifChar = Just "beats"} helmAttrs loc `shouldBe` False
    it "filters set-only" $
      matchesFilter emptyFilter {ifSetOnly = True} helmAttrs loc `shouldBe` False

  describe "itemRows (real data smoke test)" $
    it "a composed query returns consistent rows" $
      withDataFile (gamePath "database/database.arz") $ \_ -> do
        Right db <- loadGameDb dataDir
        Right owned <- loadOwnedItems dataDir
        let rows = itemRows db emptyFilter {ifType = Just "helm", ifResists = ["fire"]} owned
        length rows > 0 `shouldBe` True
        all (\r -> irType r == "head") rows `shouldBe` True
        all (\r -> "fire" `elem` irResists r) rows `shouldBe` True
