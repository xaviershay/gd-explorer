module GrimDawn.Report.ItemsSpec (spec) where

import qualified Data.Set as Set
import qualified Data.Text as T
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
    , iaResistBonuses = ["45% Fire", "40% Cold"]
    , iaDamage = Set.empty
    , iaDamageBonuses = []
    , iaBonuses = []
    , iaSkillBonuses = ["+1 to all Skills", "Grants Ring of Steel"]
    , iaIsSet = False
    , iaSetRecord = Nothing
    , iaBitmap = Nothing
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
    it "filters by skill bonus substring (case-insensitive)" $ do
      matchesFilter emptyFilter {ifSkills = ["ring of steel"]} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifSkills = ["all skills"]} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifSkills = ["laceration"]} helmAttrs loc `shouldBe` False
    it "requires all requested skill substrings" $
      matchesFilter emptyFilter {ifSkills = ["all skills", "laceration"]} helmAttrs loc
        `shouldBe` False
    it "matches any-skill query (empty string) only when a bonus is present" $ do
      matchesFilter emptyFilter {ifSkills = [""]} helmAttrs loc `shouldBe` True
      matchesFilter emptyFilter {ifSkills = [""]} helmAttrs {iaSkillBonuses = []} loc
        `shouldBe` False

  describe "itemRows (real data smoke test)" $
    it "a composed query returns consistent rows" $
      withDataFile (gamePath "database/database.arz") $ \_ -> do
        Right db <- loadGameDb dataDir
        Right owned <- loadOwnedItems dataDir
        let rows = itemRows db emptyFilter {ifType = Just "helm", ifResists = ["fire"]} owned
        length rows > 0 `shouldBe` True
        all (\r -> irType r == "head") rows `shouldBe` True
        all (\r -> any ("Fire" `T.isInfixOf`) (irResists r)) rows `shouldBe` True
