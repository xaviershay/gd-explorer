module GrimDawn.ItemSpec (spec) where

import qualified Data.Set as Set
import qualified Data.Text as T
import GrimDawn.Db (loadGameDb)
import GrimDawn.Gdc
  ( Item (..)
  , charEquipped
  , charInventory
  , charPersonalStash
  , loadCharacterFile
  )
import GrimDawn.Item
import Test.Hspec
import TestHelpers (dataDir, gamePath, withDataFile)

-- A bare item with all-empty fields; set the names we care about per test.
blankItem :: Item
blankItem =
  Item
    { itemBaseName = ""
    , itemPrefixName = ""
    , itemSuffixName = ""
    , itemModifierName = ""
    , itemTransmuteName = ""
    , itemSeed = 0
    , itemRelicName = ""
    , itemRelicBonus = ""
    , itemRelicSeed = 0
    , itemAugmentName = ""
    , itemUnknown = 0
    , itemAugmentSeed = 0
    , itemRelicCompletionLevel = 0
    , itemStackCount = 1
    }

spec :: Spec
spec = do
  describe "relatedRecordNames" $
    it "keeps only non-empty records/ paths from the name fields" $ do
      let it_ =
            blankItem
              { itemBaseName = "records/items/base.dbr"
              , itemPrefixName = "records/items/prefix/p.dbr"
              , itemSuffixName = "" -- empty -> dropped
              , itemRelicName = "notarecord"
              }
      relatedRecordNames it_
        `shouldBe` ["records/items/base.dbr", "records/items/prefix/p.dbr"]

  describe "itemAttrs / itemDisplayName (real database)" $ do
    it "names a known equipped item and derives sane attributes" $
      withDataFile (gamePath "database/database.arz") $ \_ -> do
        Right db <- loadGameDb dataDir
        Right c <- loadCharacterFile "test/fixtures/Odie.gdc"
        -- "Whisperer of Secrets" is Odie's equipped legendary helm.
        case filter
          (\i -> iaDisplayName (itemAttrs i db) == "Whisperer of Secrets")
          (charEquipped c) of
          (it_ : _) -> do
            let a = itemAttrs it_ db
            iaType a `shouldBe` Just "head"
            iaClassification a `shouldBe` Just "Legendary" -- rarity
            iaLevelRequirement a `shouldBe` Just 65
            Set.member "aether" (iaResists a) `shouldBe` True
            -- damage bonus: the helm has offensivePierceModifier 32
            ("32% Pierce" `elem` iaDamageBonuses a) `shouldBe` True
            -- skill bonuses: it augments two skills and grants one
            null (iaSkillBonuses a) `shouldBe` False
          [] -> expectationFailure "expected to find 'Whisperer of Secrets'"

    it "detects at least one owned set item with a set record" $
      withDataFile (gamePath "database/database.arz") $ \_ -> do
        Right db <- loadGameDb dataDir
        Right c <- loadCharacterFile "test/fixtures/Odie.gdc"
        let allItems = charEquipped c ++ charInventory c ++ charPersonalStash c
            setItems = filter (\i -> iaIsSet (itemAttrs i db)) allItems
        length setItems > 0 `shouldBe` True
        all (\i -> case iaSetRecord (itemAttrs i db) of
                     Just s -> T.isPrefixOf "records/" s
                     Nothing -> False) setItems
          `shouldBe` True
