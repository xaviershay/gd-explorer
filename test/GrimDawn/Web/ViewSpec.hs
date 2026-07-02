module GrimDawn.Web.ViewSpec (spec) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.HashMap.Strict as HM
import Data.List (isInfixOf, sortOn)
import GrimDawn.Aggregate (Location (..), OwnedItem (..))
import GrimDawn.Arz (Value (..))
import GrimDawn.Db (GameDb (..))
import GrimDawn.Gdc (Character (..), Item (..), Skill (..))
import GrimDawn.Report.Stats (AttackKind (..), Difficulty (..))
import GrimDawn.Web.View
import Test.Hspec

blankItem :: Item
blankItem = Item "" "" "" "" "" 0 "" "" 0 "" 0 0 0 1

-- one set "Test Set" with two members, plus a helm item record for gear tests.
synthDb :: GameDb
synthDb =
  GameDb
    { gdbRecords =
        HM.fromList
          [ ( "records/items/lootsets/test.dbr"
            , HM.fromList
                [ ("setName", VString "Test Set")
                , ("setMembers", VList [VString "m1", VString "m2"])
                , -- cumulative bonus arrays: +50 DA newly unlocked at 2 pieces
                  ("characterDefensiveAbility", VList [VFloat 0, VFloat 50])
                ]
            )
          , ( "m1"
            , HM.fromList
                [ ("itemNameTag", VString "Member One")
                , ("itemClassification", VString "Epic")
                , ("levelRequirement", VInt 65)
                ]
            )
          , ("m2", HM.fromList [("itemNameTag", VString "Member Two")])
          , ( "records/items/helm.dbr"
            , HM.fromList
                [ ("Class", VString "ArmorProtective_Head")
                , ("defensiveFire", VFloat 40)
                ]
            )
          , ( "records/items/weapon.dbr"
            , HM.fromList
                [ ("Class", VString "WeaponMelee_Sword")
                , ("offensivePhysicalMin", VFloat 100)
                , ("offensivePhysicalMax", VFloat 100)
                ]
            )
          , ( "records/skills/playerclass01/atk1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_attack.tpl")
                , ("weaponDamagePct", VFloat 100)
                , ("offensiveFireMin", VFloat 50)
                , ("offensiveFireMax", VFloat 50)
                , ("skillCooldownTime", VFloat 2)
                ]
            )
          ]
    , gdbText = HM.empty
    }

owned :: [OwnedItem]
owned = [OwnedItem blankItem {itemBaseName = "m1"} SharedStash]

hero :: Character
hero =
  Character "Hero" "tagClass" 50 True [blankItem {itemBaseName = "records/items/helm.dbr"}] [] [] [] 0 0 0 0 0 []

weapon :: Item
weapon = blankItem {itemBaseName = "records/items/weapon.dbr"}

heroWithAttack :: Character
heroWithAttack =
  hero
    { charEquipped = charEquipped hero ++ [weapon]
    , charSkills = [Skill "records/skills/playerclass01/atk1.dbr" 1 True 0 0 0 False False "" ""]
    }

spec :: Spec
spec = do
  describe "setsView" $ do
    let [sv] = setsView synthDb [] owned
    it "summarises owned vs total and members" $ do
      svName sv `shouldBe` "Test Set"
      svOwnedCount sv `shouldBe` 1
      svTotal sv `shouldBe` 2
      svComplete sv `shouldBe` False
      svLevel sv `shouldBe` Just 65 -- max member level requirement
      length (svMembers sv) `shouldBe` 2
    it "records member holdings and embedded item attributes" $ do
      let m1 = head (svMembers sv)
      smvOwned m1 `shouldBe` True
      map hvLocation (smvHoldings m1) `shouldBe` ["shared stash"]
      gvClassification (smvGear m1) `shouldBe` Just "Epic"
      gvLevelRequirement (smvGear m1) `shouldBe` Just 65
    it "attaches the per-tier set bonus newly unlocked by each item" $ do
      let [m1, m2] = svMembers sv
      smvSetTier m1 `shouldBe` 1
      bgBonuses (smvSetBonus m1) `shouldBe` [] -- nothing new at 1 piece
      smvSetTier m2 `shouldBe` 2
      bgBonuses (smvSetBonus m2) `shouldBe` ["+50 Defensive Ability"] -- 0 -> 50 at 2 pieces
    it "encodes JSON with camelCase keys (prefix stripped)" $ do
      let s = BL.unpack (encode sv)
      ("ownedCount" `isInfixOf` s) `shouldBe` True
      ("members" `isInfixOf` s) `shouldBe` True
      ("svOwnedCount" `isInfixOf` s) `shouldBe` False

  describe "setsView transmute eligibility" $ do
    it "leaves a missing member non-transmutable with no excess and no blueprints" $ do
      let [sv] = setsView synthDb [] owned
          [_, m2] = svMembers sv
      smvTransmutable m2 `shouldBe` False

    it "flags a missing member transmutable when another member has excess copies" $ do
      let dupOwned =
            [ OwnedItem blankItem {itemBaseName = "m1"} SharedStash
            , OwnedItem blankItem {itemBaseName = "m1"} SharedStash
            ]
          [sv] = setsView synthDb [] dupOwned
          [_, m2] = svMembers sv
      smvOwned m2 `shouldBe` False
      smvTransmutable m2 `shouldBe` True

    it "flags a missing member transmutable when a different set member has a learned blueprint" $ do
      let [sv] = setsView synthDb ["m1"] owned
          [_, m2] = svMembers sv
      smvCraftable m2 `shouldBe` False -- the blueprint is for m1, not m2
      smvTransmutable m2 `shouldBe` True

    it "does not double-signal a missing member that already has its own blueprint" $ do
      let [sv] = setsView synthDb ["m2"] owned
          [_, m2] = svMembers sv
      smvCraftable m2 `shouldBe` True
      smvTransmutable m2 `shouldBe` False

  describe "attackBreakdownView" $ do
    it "returns Nothing for an unknown attack name" $
      attackBreakdownView synthDb owned [] Ultimate heroWithAttack "Nonexistent" Nothing Active `shouldBe` Nothing

    it "encodes a known attack's breakdown with category strings and a sorted impact list" $ do
      case attackBreakdownView synthDb owned [] Ultimate heroWithAttack "Weapon Attack" Nothing Active of
        Nothing -> expectationFailure "expected a breakdown"
        Just abv -> do
          let json = BL.unpack (encode abv)
          ("\"kind\":\"active\"" `isInfixOf` json) `shouldBe` True
          ("\"category\":\"gear\"" `isInfixOf` json) `shouldBe` True
          let impacts = map (abs . sivDpsImpact) (abvSourcesByImpact abv)
          impacts `shouldBe` sortOn negate impacts -- sorted by |impact| descending

  describe "detailView" $ do
    let dv = detailView synthDb [] [] Ultimate hero
    it "carries character header and equipped gear" $ do
      cdvName dv `shouldBe` "Hero"
      cdvLevel dv `shouldBe` 50
      cdvHardcore dv `shouldBe` True
      cdvClassName dv `shouldBe` "tagClass" -- falls back to raw tag (no localization)
      length (cdvGear dv) `shouldBe` 1
    it "derives gear type from the item record" $
      gvType (head (cdvGear dv)) `shouldBe` Just "head"

  describe "summaryView" $
    it "counts equipped pieces" $ do
      let cv = summaryView synthDb hero
      csvEquippedCount cv `shouldBe` 1
      csvLevel cv `shouldBe` 50
