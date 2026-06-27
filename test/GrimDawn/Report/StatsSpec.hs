module GrimDawn.Report.StatsSpec (spec) where

import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import GrimDawn.Arz (Value (..))
import GrimDawn.Db (GameDb (..))
import GrimDawn.Gdc (Character (..), Item (..), Skill (..))
import GrimDawn.Report.Stats
  ( AttackDps (..)
  , AttackKind (..)
  , BuffToggle (..)
  , Difficulty (..)
  , UpgradeRow (..)
  , attackDps
  , defaultWeights
  , devotionSources
  , findUpgrades
  , noBuffs
  , overlay
  , overlayAt
  , parseBuffs
  , parseProcController
  , renderStats
  , skillSources
  )
import Test.Hspec

blankItem :: Item
blankItem = Item "" "" "" "" "" 0 "" "" 0 "" 0 0 0 1

mkSkill :: T.Text -> Skill
mkSkill n = Skill n 1 True 1 0 0 False False "" ""

mkSkillLvl :: T.Text -> Int -> Skill
mkSkillLvl n lvl = Skill n (fromIntegral lvl) True 0 0 0 False False "" ""

mkChar :: [Skill] -> Character
mkChar sks = Character "Test" "" 100 False [] [] [] sks 0 0 0

-- the skill rows (excluding the synthetic bare "Weapon Attack" baseline)
skillRows :: [AttackDps] -> [AttackDps]
skillRows = filter ((/= "Weapon Attack") . adName)

-- a helm with 90% fire resist, +5% max fire resist, +100 OA, +50 DA
synthDb :: GameDb
synthDb =
  GameDb
    { gdbRecords =
        HM.fromList
          [ ( "records/items/helm.dbr"
            , HM.fromList
                [ ("Class", VString "ArmorProtective_Head")
                , ("defensiveFire", VFloat 90)
                , ("defensiveFireMaxResist", VFloat 5)
                , ("characterOffensiveAbility", VFloat 100)
                , ("characterDefensiveAbility", VFloat 50)
                ]
            )
          , ( "records/items/helmB.dbr"
            , HM.fromList [("Class", VString "ArmorProtective_Head"), ("defensiveCold", VFloat 30)]
            )
          , ( "records/items/ring.dbr"
            , HM.fromList [("Class", VString "ArmorJewelry_Ring"), ("defensiveChaos", VFloat 20)]
            )
          , ( "records/items/ringB.dbr"
            , HM.fromList [("Class", VString "ArmorJewelry_Ring"), ("defensiveChaos", VFloat 40)]
            )
          , -- a devotion star granting +18 Defensive Ability
            ( "records/skills/devotion/tier1_15a.dbr"
            , HM.fromList [("characterDefensiveAbility", VFloat 18)]
            )
          , -- a permanent passive: OA scales 10/20 by rank
            ( "records/skills/playerclass01/passive1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_passive.tpl")
                , ("characterOffensiveAbility", VList [VFloat 10, VFloat 20])
                ]
            )
          , -- a temporary (duration) self-buff
            ( "records/skills/playerclass01/buff1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_buffselfduration.tpl")
                , ("characterDefensiveAbility", VFloat 30)
                ]
            )
          , -- an orphan modifier (no sibling with a category -> never folded in)
            ( "records/skills/playerclass01/mod1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_modifier.tpl")
                , ("characterStrength", VFloat 99)
                ]
            )
          , -- a modifier of passive1 (shares base "passive"): grants fire resist
            ( "records/skills/playerclass01/passive2.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_modifier.tpl")
                , ("defensiveFire", VList [VFloat 25, VFloat 40])
                ]
            )
          , -- a weapon attack: 100% weapon damage + 50 flat fire, 2s cooldown
            ( "records/skills/playerclass01/atk1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_attack.tpl")
                , ("weaponDamagePct", VFloat 100)
                , ("offensiveFireMin", VFloat 50)
                , ("offensiveFireMax", VFloat 50)
                , ("skillCooldownTime", VFloat 2)
                ]
            )
          , -- a modifier of atk1 (shares base "atk"): +20 cold, -0.5s cooldown
            ( "records/skills/playerclass01/atk1b.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_modifier.tpl")
                , ("offensiveColdMin", VFloat 20)
                , ("offensiveColdMax", VFloat 20)
                , ("skillCooldownTime", VFloat (-0.5))
                ]
            )
          , -- an attack with a fire DoT: 100 physical hit + 10/s burn over 3s
            ( "records/skills/playerclass01/burn1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_attack.tpl")
                , ("skillCooldownTime", VFloat 2)
                , ("offensivePhysicalMin", VFloat 100)
                , ("offensivePhysicalMax", VFloat 100)
                , ("offensiveSlowFireMin", VFloat 10)
                , ("offensiveSlowFireMax", VFloat 10)
                , ("offensiveSlowFireDurationMin", VFloat 3)
                ]
            )
          , -- an attack (4s cd) with a chance-based cooldown reset modifier
            ( "records/skills/playerclass01/cdr1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_attack.tpl")
                , ("skillCooldownTime", VFloat 4)
                , ("offensivePhysicalMin", VFloat 100)
                , ("offensivePhysicalMax", VFloat 100)
                ]
            )
          , ( "records/skills/playerclass01/cdr1b.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_modifier.tpl")
                , ("skillCooldownReduction", VFloat 100)
                , ("skillCooldownReductionChance", VFloat 25)
                ]
            )
          , -- an item that grants a proc: 50% chance on attack, 2s cooldown
            ( "records/items/relicProc.dbr"
            , HM.fromList
                [ ("itemSkillName", VString "records/skills/itemskills/proc1.dbr")
                , ("itemSkillAutoController", VString "records/controllers/itemskills/cast_@enemyonattack_50%.dbr")
                , ("itemSkillLevelEq", VString "1")
                ]
            )
          , ( "records/skills/itemskills/proc1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_attackprojectile.tpl")
                , ("skillDisplayName", VString "Testproc")
                , ("offensiveFireMin", VFloat 100)
                , ("offensiveFireMax", VFloat 100)
                , ("skillCooldownTime", VFloat 2)
                ]
            )
          ]
    , gdbText = HM.empty
    }

helm, helmB, ring, ringB :: Item
helm = blankItem {itemBaseName = "records/items/helm.dbr"}
helmB = blankItem {itemBaseName = "records/items/helmB.dbr"}
ring = blankItem {itemBaseName = "records/items/ring.dbr"}
ringB = blankItem {itemBaseName = "records/items/ringB.dbr"}

items :: [Item]
items = [blankItem {itemBaseName = "records/items/helm.dbr"}]

spec :: Spec
spec = describe "renderStats (synthetic)" $ do
  it "applies the ultimate -50 penalty and the +max-resist cap" $ do
    let out = renderStats False Ultimate (mkChar []) [] synthDb items
    -- 90 gear - 50 penalty = 40, under cap (80 + 5)
    ("40%" `T.isInfixOf` out) `shouldBe` True
    ("cap 85" `T.isInfixOf` out) `shouldBe` True

  it "caps and reports overcap on normal difficulty" $ do
    let out = renderStats False Normal (mkChar []) [] synthDb items
    -- 90 gear, capped at 85, 5 over
    ("85%" `T.isInfixOf` out) `shouldBe` True
    ("+5 over" `T.isInfixOf` out) `shouldBe` True

  it "totals offensive and defensive ability from gear" $ do
    let out = renderStats False Normal (mkChar []) [] synthDb items
    ("+100" `T.isInfixOf` out) `shouldBe` True
    ("+50" `T.isInfixOf` out) `shouldBe` True

  it "flags an unresisted type as LOW under penalty" $ do
    let out = renderStats False Ultimate (mkChar []) [] synthDb items
    -- physical resist is 0 here -> -50% under ultimate
    ("LOW" `T.isInfixOf` out) `shouldBe` True

  it "overlay replaces the item occupying the same slot" $
    map itemBaseName (overlay synthDb [helm] [helmB])
      `shouldBe` ["records/items/helmB.dbr"]

  it "overlay adds an item with no matching slot" $
    map itemBaseName (overlay synthDb [helm] [ring])
      `shouldBe` ["records/items/helm.dbr", "records/items/ring.dbr"]

  it "overlayAt replaces the n-th equipped item of the candidate's slot type" $ do
    -- two rings equipped (ring then ringB); the candidate is ringB, so the swap is
    -- observable: occurrence 0 = ring1, occurrence 1 = ring2.
    map itemBaseName (overlayAt synthDb 0 [helm, ring, ringB] ringB)
      `shouldBe` ["records/items/helm.dbr", "records/items/ringB.dbr", "records/items/ringB.dbr"]
    map itemBaseName (overlayAt synthDb 1 [helm, ring, ringB] ringB)
      `shouldBe` ["records/items/helm.dbr", "records/items/ring.dbr", "records/items/ringB.dbr"]

  it "overlayAt appends when the requested slot occurrence is empty" $
    -- only one ring equipped; targeting ring2 (occurrence 1) fills the empty slot
    map itemBaseName (overlayAt synthDb 1 [helm, ring] ringB)
      `shouldBe` ["records/items/helm.dbr", "records/items/ring.dbr", "records/items/ringB.dbr"]

  it "overlay inherits the replaced item's component and augment" $ do
    let old =
          helm
            { itemRelicName = "records/items/comp.dbr"
            , itemRelicBonus = "records/items/bonus.dbr"
            , itemAugmentName = "records/items/aug.dbr"
            }
    case overlay synthDb [old] [helmB] of -- helmB is bare, same (head) slot
      [r] -> do
        itemBaseName r `shouldBe` "records/items/helmB.dbr"
        itemRelicName r `shouldBe` "records/items/comp.dbr"
        itemRelicBonus r `shouldBe` "records/items/bonus.dbr"
        itemAugmentName r `shouldBe` "records/items/aug.dbr"
      _ -> expectationFailure "expected one item"

  it "overlay keeps the candidate's own component over the replaced item's" $ do
    let old = helm {itemRelicName = "records/items/oldcomp.dbr"}
        cand = helmB {itemRelicName = "records/items/candcomp.dbr"}
    case overlay synthDb [old] [cand] of
      [r] -> itemRelicName r `shouldBe` "records/items/candcomp.dbr"
      _ -> expectationFailure "expected one item"

  it "includes devotion passive bonuses as extra sources" $ do
    let ch = mkChar [mkSkill "records/skills/devotion/tier1_15a.dbr"]
        extra = devotionSources synthDb ch
        out = renderStats False Normal ch extra synthDb []
    length extra `shouldBe` 1
    ("Defensive Ability" `T.isInfixOf` out) `shouldBe` True
    ("+18" `T.isInfixOf` out) `shouldBe` True

  it "excludes celestial-power (_skill) devotion procs from passives" $ do
    let ch = mkChar [mkSkill "records/skills/devotion/tier1_19e_skill.dbr"]
    devotionSources synthDb ch `shouldBe` []

  it "skill buffs respect the category toggle and skip modifiers" $ do
    let ch =
          mkChar
            [ mkSkillLvl "records/skills/playerclass01/passive1.dbr" 2
            , mkSkillLvl "records/skills/playerclass01/buff1.dbr" 1
            , mkSkillLvl "records/skills/playerclass01/mod1.dbr" 1
            ]
        permOnly = BuffToggle True False False
    -- nothing folded in when no categories enabled
    skillSources noBuffs [] synthDb ch `shouldBe` []
    -- permanent only: the passive, resolved at rank 2 (=20 OA); modifier excluded
    map fst (skillSources permOnly [] synthDb ch)
      `shouldBe` ["records/skills/playerclass01/passive1.dbr"]
    ("+20" `T.isInfixOf` renderStats False Normal ch (skillSources permOnly [] synthDb ch) synthDb [])
      `shouldBe` True
    -- all categories: passive + duration buff, still no modifier
    map fst (skillSources (BuffToggle True True True) [] synthDb ch)
      `shouldBe` ["records/skills/playerclass01/passive1.dbr", "records/skills/playerclass01/buff1.dbr"]

  it "folds a skill modifier in under its parent skill's category" $ do
    let ch =
          mkChar
            [ mkSkillLvl "records/skills/playerclass01/passive1.dbr" 1
            , mkSkillLvl "records/skills/playerclass01/passive2.dbr" 1
            ]
        perm = BuffToggle True False False
        names = map fst (skillSources perm [] synthDb ch)
        out = renderStats False Normal ch (skillSources perm [] synthDb ch) synthDb []
    -- passive2 inherits passive1's Permanent category and contributes fire resist
    ("records/skills/playerclass01/passive2.dbr" `elem` names) `shouldBe` True
    -- the stats resist line shows Fire at 25%
    any (\l -> "Fire" `T.isInfixOf` l && "25%" `T.isInfixOf` l) (T.lines out) `shouldBe` True

  it "does not fold an orphan modifier (no parent with a category)" $ do
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/mod1.dbr" 1]
    skillSources (BuffToggle True True True) [] synthDb ch `shouldBe` []

  it "scales skill buffs by +skills from the context" $ do
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/passive1.dbr" 1]
        ctx = [("gear", HM.fromList [("augmentAllLevel", VFloat 1)])]
        perm = BuffToggle True False False
        withPlus = renderStats False Normal ch (skillSources perm ctx synthDb ch) synthDb []
        without = renderStats False Normal ch (skillSources perm [] synthDb ch) synthDb []
    -- invested rank 1 -> +10 OA; with +1 all skills -> rank 2 -> +20 OA
    ("+10" `T.isInfixOf` without) `shouldBe` True
    ("+20" `T.isInfixOf` withPlus) `shouldBe` True

  it "findUpgrades scores an overlay and keeps net-positive candidates" $ do
    -- helm grants 90% fire (capped 85), +100 OA, +50 DA; over empty gear it is an upgrade
    let rows = findUpgrades defaultWeights 80 Normal 0 (mkChar []) [] synthDb [] [("shared stash", helm)]
    case rows of
      (r : _) -> do
        (urScore r > 0) `shouldBe` True
        any (\(n, _, _) -> n == "Fire") (urResists r) `shouldBe` True
        urOa r `shouldBe` 100
        urDa r `shouldBe` 50
        urLocation r `shouldBe` "shared stash"
      [] -> expectationFailure "expected helm to rank as an upgrade over empty gear"

  it "attackDps estimates per-hit and DPS from a weapon attack" $ do
    -- 100% weapon damage off a 100-avg physical weapon + 50 flat fire, 2s cooldown
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1]
        sources = [("wpn", HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])]
    case skillRows (attackDps synthDb sources ch) of
      (r : _) -> do
        adPerHit r `shouldBe` 150 -- 100 weapon + 50 fire
        adDps r `shouldBe` 75 -- /2s cooldown
        ("cooldown" `T.isInfixOf` adRate r) `shouldBe` True
        lookup "Physical" (adTypes r) `shouldBe` Just 100
        lookup "Fire" (adTypes r) `shouldBe` Just 50
      [] -> expectationFailure "expected an attack DPS row"

  it "attackDps applies damage-type conversions" $ do
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1]
        -- weapon plus a global 100% Fire -> Poison (acid) conversion source
        sources =
          [ ("wpn", HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])
          , ( "conv"
            , HM.fromList
                [ ("conversionInType", VString "Fire")
                , ("conversionOutType", VString "Poison")
                , ("conversionPercentage", VFloat 100)
                ]
            )
          ]
    case skillRows (attackDps synthDb sources ch) of
      (r : _) -> do
        lookup "Fire" (adTypes r) `shouldBe` Nothing -- fire converted away
        lookup "Acid" (adTypes r) `shouldBe` Just 50 -- 50 flat fire -> acid
        lookup "Physical" (adTypes r) `shouldBe` Just 100
      [] -> expectationFailure "expected an attack DPS row"

  it "attackDps adds retaliation damage to attack" $ do
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1]
        -- 200 flat fire retaliation + 50% retaliation-added-to-attack (global)
        sources =
          [ ("wpn", HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])
          , ( "retal"
            , HM.fromList
                [ ("retaliationFireMin", VFloat 200)
                , ("retaliationFireMax", VFloat 200)
                , ("retaliationDamagePct", VFloat 50)
                ]
            )
          ]
    case skillRows (attackDps synthDb sources ch) of
      (r : _) ->
        -- 50 skill-flat fire + 50% of 200 retaliation = 100, x100% weapon dmg
        lookup "Fire" (adTypes r) `shouldBe` Just 150
      [] -> expectationFailure "expected an attack DPS row"

  it "attackDps folds a skill's modifiers in (added damage + cooldown reduction)" $ do
    let ch =
          mkChar
            [ mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1
            , mkSkillLvl "records/skills/playerclass01/atk1b.dbr" 1
            ]
        sources = [("wpn", HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])]
    case skillRows (attackDps synthDb sources ch) of
      [r] -> do
        -- only the primary attack emits; the modifier's cold and -0.5s fold in
        lookup "Cold" (adTypes r) `shouldBe` Just 20
        lookup "Fire" (adTypes r) `shouldBe` Just 50
        ("1.5s cooldown" `T.isInfixOf` adRate r) `shouldBe` True
      rs -> expectationFailure ("expected exactly one row, got " ++ show (length rs))

  it "attackDps includes damage-over-time (per-application total)" $ do
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/burn1.dbr" 1]
    case attackDps synthDb [] ch of
      [r] -> do
        lookup "Physical" (adTypes r) `shouldBe` Just 100 -- immediate hit
        lookup "Burn (dot)" (adTypes r) `shouldBe` Just 30 -- 10/s x 3s
      rs -> expectationFailure ("expected one row, got " ++ show (length rs))

  it "attackDps treats chance-based cooldown reset as expected value" $ do
    -- 4s base cd, modifier with 25% chance of 100% reduction -> 25% expected CDR
    let ch =
          mkChar
            [ mkSkillLvl "records/skills/playerclass01/cdr1.dbr" 1
            , mkSkillLvl "records/skills/playerclass01/cdr1b.dbr" 1
            ]
    case attackDps synthDb [] ch of
      [r] -> ("3.0s cooldown" `T.isInfixOf` adRate r) `shouldBe` True -- 4 x (1 - 0.25)
      rs -> expectationFailure ("expected one row, got " ++ show (length rs))

  it "includes a bare Weapon Attack row (100% weapon damage)" $ do
    let sources = [("wpn", HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])]
    case filter ((== "Weapon Attack") . adName) (attackDps synthDb sources (mkChar [])) of
      [r] -> do
        adRank r `shouldBe` Nothing
        lookup "Physical" (adTypes r) `shouldBe` Just 100
      _ -> expectationFailure "expected a Weapon Attack row"

  it "applies conversions to damage-over-time (Burn -> Poison)" $ do
    let ch = mkChar [mkSkillLvl "records/skills/playerclass01/burn1.dbr" 1]
        sources =
          [ ( "conv"
            , HM.fromList
                [ ("conversionInType", VString "Fire")
                , ("conversionOutType", VString "Poison")
                , ("conversionPercentage", VFloat 100)
                ]
            )
          ]
    case skillRows (attackDps synthDb sources ch) of
      [r] -> do
        lookup "Burn (dot)" (adTypes r) `shouldBe` Nothing -- converted away
        lookup "Poison (dot)" (adTypes r) `shouldBe` Just 30 -- 10/s x 3s, now Poison
      rs -> expectationFailure ("expected one skill row, got " ++ show (length rs))

  it "parseProcController reads attack-driven trigger + chance, skipping others" $ do
    parseProcController "records/controllers/itemskills/cast_@enemyonattack_20%.dbr" `shouldBe` Just ("attack", 0.2)
    parseProcController "x/cast_@enemyonanyhit_100%.dbr" `shouldBe` Just ("hit", 1.0)
    parseProcController "x/cast_@enemyonmeleehit_15%.dbr" `shouldBe` Just ("melee hit", 0.15)
    parseProcController "x/cast_@enemyonattackcrit_30%.dbr" `shouldBe` Nothing -- needs crit
    parseProcController "x/cast_@enemyonblock_25%.dbr" `shouldBe` Nothing -- not attack-driven

  it "attackDps adds an item-granted proc with expected-value DPS" $ do
    -- 100 fire, 2s cd, 50% on attack; aps = 1 (no attack-speed source)
    let sources =
          [ ("wpn", HM.fromList [("offensivePhysicalMin", VFloat 1), ("offensivePhysicalMax", VFloat 1)])
          , ("relic", gdbRecords synthDb HM.! "records/items/relicProc.dbr")
          ]
    case filter ((== Triggered) . adKind) (attackDps synthDb sources (mkChar [])) of
      [r] -> do
        adName r `shouldBe` "Testproc"
        lookup "Fire" (adTypes r) `shouldBe` Just 100
        -- interval = cd 2 + 1/(0.5*1) = 4s  ->  100/4 = 25 dps
        round (adDps r) `shouldBe` (25 :: Integer)
        ("50% on attack" `T.isInfixOf` adRate r) `shouldBe` True
      rs -> expectationFailure ("expected one proc row, got " ++ show (length rs))

  it "parseBuffs reads category lists" $ do
    parseBuffs "permanent,proc" `shouldBe` Right (BuffToggle True False True)
    parseBuffs "all" `shouldBe` Right (BuffToggle True True True)
    parseBuffs "none" `shouldBe` Right noBuffs
    case parseBuffs "bogus" of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected parse failure for bogus category"
