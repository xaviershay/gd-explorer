module GrimDawn.Report.CharacterSpec (spec) where

import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import GrimDawn.Arz (Value (..))
import GrimDawn.Db (GameDb (..))
import GrimDawn.Gdc (Character (..), Item (..), Skill (..))
import GrimDawn.Report.Character (renderCharacter)
import Test.Hspec

blankItem :: Item
blankItem = Item "" "" "" "" "" 0 "" "" 0 "" 0 0 0 1

mkSkill :: T.Text -> Int -> Skill
mkSkill name lvl = Skill name (fromIntegral lvl) True 0 0 0 False False "" ""

-- synthetic DB: a helm base record, a mastery bar + class skill, and an Imp
-- constellation (one ordinary star + its granted celestial-power star).
synthDb :: GameDb
synthDb =
  GameDb
    { gdbRecords =
        HM.fromList
          [ ( "records/items/helm.dbr"
            , HM.fromList
                [ ("itemNameTag", VString "Test Helm")
                , ("Class", VString "ArmorProtective_Head")
                , ("itemClassification", VString "Epic")
                , ("levelRequirement", VInt 25)
                , ("defensiveProtection", VFloat 450)
                , ("characterIncreasedExperience", VFloat 8)
                , ("defensiveFire", VFloat 45)
                , ("defensivePhysical", VFloat 8)
                , ("offensiveTotalDamageModifier", VFloat 12)
                , ("retaliationFireMax", VFloat 200)
                , ("itemSetName", VString "records/items/lootsets/testset.dbr")
                ]
            )
          , -- a one-piece set whose bonus is active immediately (index 0)
            ( "records/items/lootsets/testset.dbr"
            , HM.fromList
                [ ("setName", VString "Test Set")
                , ("setMembers", VList [VString "records/items/helm.dbr"])
                , ("defensiveProtectionModifier", VList [VFloat 12])
                ]
            )
          , skillRec "records/skills/playerclass02/_classtraining_class02.dbr" "Demolitionist"
          , skillRec "records/skills/playerclass02/grenado1.dbr" "Grenado"
          , skillRec "records/skills/devotion/tier1_19a.dbr" "Imp"
          , skillRec "records/skills/devotion/tier1_19e_skill.dbr" "Aetherfire"
          ]
    , gdbText = HM.fromList [("tagSkillClassName0206", "Elementalist")]
    }
  where
    skillRec n disp = (n, HM.fromList [("skillDisplayName", VString disp)])

char :: Character
char =
  Character
    { charName = "Test Char"
    , charClassName = "tagSkillClassName0206"
    , charLevel = 41
    , charHardcore = False
    , charEquipped = [blankItem {itemBaseName = "records/items/helm.dbr"}]
    , charInventory = []
    , charPersonalStash = []
    , charSkills =
        [ mkSkill "records/skills/playerclass02/_classtraining_class02.dbr" 40
        , mkSkill "records/skills/playerclass02/grenado1.dbr" 1
        , mkSkill "records/skills/devotion/tier1_19a.dbr" 1
        , mkSkill "records/skills/devotion/tier1_19e_skill.dbr" 1
        ]
    }

spec :: Spec
spec = describe "renderCharacter (synthetic)" $ do
  let out = renderCharacter False synthDb char
      contains needle = needle `T.isInfixOf` out

  it "renders the header with the resolved class combo" $
    contains "Test Char  —  Level 41  Elementalist" `shouldBe` True

  it "lists equipped gear with rarity, slot, and level" $
    contains "Test Helm [Epic] head lvl 25" `shouldBe` True

  it "renders extra stat bonuses (armor, total damage, experience, retaliation, ...)" $ do
    contains "+450 Armor" `shouldBe` True
    contains "+12% to All Damage" `shouldBe` True
    contains "+8% Experience Gained" `shouldBe` True
    contains "+200 Fire Retaliation" `shouldBe` True

  it "renders resistance amounts, including physical" $ do
    contains "45% Fire" `shouldBe` True
    contains "8% Physical" `shouldBe` True

  it "groups skills under their mastery with its rank" $ do
    contains "Demolitionist (40)" `shouldBe` True
    contains "+1 Grenado" `shouldBe` True

  it "groups devotions by constellation, counting stars and the granted power" $ do
    contains "Devotions (2 points):" `shouldBe` True
    contains "Imp  (2 stars)  grants Aetherfire" `shouldBe` True

  it "shows active set bonuses aggregated per set" $ do
    contains "Set Bonuses:" `shouldBe` True
    contains "Test Set  (1/1)" `shouldBe` True
    contains "Increases Armor by 12%" `shouldBe` True

  it "omits colour codes when colouring is disabled" $
    contains "\ESC[" `shouldBe` False
