{-# LANGUAGE DeriveGeneric #-}

-- | JSON view models for the local web UI. These are thin, serializable records
-- built from the existing domain reports — they add presentation shape (and
-- 'ToJSON' instances), not new computation. The heavy lifting still lives in
-- 'GrimDawn.Report.Sets.setReport' and 'GrimDawn.Item.itemAttrs'.
module GrimDawn.Web.View
  ( SetView (..)
  , SetMemberView (..)
  , BonusGroupsView (..)
  , HoldingView (..)
  , CharacterSummaryView (..)
  , CharacterDetailView (..)
  , GearView (..)
  , StatSummaryView (..)
  , ResistReductionView (..)
  , ResistView (..)
  , NamedValueView (..)
  , KeyTotalView (..)
  , DamageRowView (..)
  , AttackView (..)
  , EnhancementView (..)
  , CatalogView (..)
  , ShoppingView (..)
  , GearOverride (..)
  , SkillEntryView (..)
  , MasteryView (..)
  , ConstellationView (..)
  , setsView
  , summaryView
  , detailView
  , enhancementCatalog
  , craftableBlueprints
  , CraftableView (..)
  , skillDictionary
  , SkillInfoView (..)
  , rankEnhancements
  , RankView (..)
  , rankItems
  , ItemRankView (..)
  , SourceCategoryView
  , SourceContributionView (..)
  , TypeBreakdownView (..)
  , RetaliationTypeBreakdownView (..)
  , RetaliationBreakdownView (..)
  , RateFactorView (..)
  , TriggerView (..)
  , SourceImpactView (..)
  , AttackBreakdownView (..)
  , attackBreakdownView
  ) where

import Data.Aeson (Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Char (isDigit, isUpper, toLower)
import qualified Data.HashMap.Strict as HM
import Data.List (nub, nubBy, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import GrimDawn.Aggregate (OwnedItem (..), locationLabel)
import GrimDawn.Arz (Record, RecordDb, Value (..), valueText)
import GrimDawn.Db (GameDb (..), lookupRecord)
import GrimDawn.Gdc
  ( Character (..)
  , Item (..)
  , Skill (..)
  , emptyItemName
  , itemWithName
  )
import GrimDawn.Item
  ( ItemAttrs (..)
  , DamageRow (..)
  , characterBonuses
  , damageBonuses
  , itemAttrs
  , resistBonuses
  , skillBonuses
  , skillDisplayName
  , sumField
  )
import GrimDawn.Report.Sets
  ( SetCompletion (..)
  , SetMember (..)
  , scComplete
  , scOwnedCount
  , scTotal
  , setReport
  , smCount
  , smOwned
  )
import GrimDawn.Report.Stats
  ( AttackBreakdown (..)
  , AttackDps (..)
  , AttackKind (..)
  , BuffToggle (..)
  , Difficulty (..)
  , RateFactorDetail (..)
  , RetaliationDetail (..)
  , RetaliationTypeDetail (..)
  , ScoreBase
  , Source (..)
  , SourceAmount (..)
  , SourceCategory (..)
  , SourceImpact (..)
  , StatSummary (..)
  , TriggerDetail (..)
  , TypeDetail (..)
  , attackDps
  , attackDpsBreakdown
  , defaultUpgradeTarget
  , defaultWeights
  , devotionSources
  , inheritGear
  , masterySources
  , mkScoreBase
  , plainSources
  , resistReductionLines
  , retaliationPseudoSource
  , scoreItems
  , skillSources
  , statSources
  , statSummary
  )

--------------------------------------------------------------------------------
-- JSON encoding: drop the lowercase field prefix, e.g. @svOwnedCount@ -> @ownedCount@
--------------------------------------------------------------------------------

opts :: Options
opts = defaultOptions {fieldLabelModifier = dropPrefix}

-- drop the leading lowercase prefix (up to the first uppercase letter) and
-- lowercase the first remaining character: "svOwnedCount" -> "ownedCount".
dropPrefix :: String -> String
dropPrefix s = case dropWhile (not . isUpper) s of
  [] -> s
  (c : cs) -> toLower c : cs

--------------------------------------------------------------------------------
-- Set completion map
--------------------------------------------------------------------------------

data SetView = SetView
  { svName :: !Text
  , svRecord :: !Text
  , svOwnedCount :: !Int
  , svTotal :: !Int
  , svComplete :: !Bool
  , svLevel :: !(Maybe Int) -- representative level for banding (max member req)
  , svMembers :: ![SetMemberView]
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetView where toJSON = genericToJSON opts

data SetMemberView = SetMemberView
  { smvName :: !Text
  , smvRecord :: !Text
  , smvOwned :: !Bool
  , smvCount :: !Int
  , smvHoldings :: ![HoldingView]
  , smvGear :: !GearView -- full in-game-style attributes (rarity, stats, ...)
  , smvSetTier :: !Int -- piece count this item activates (its 1-based position)
  , smvSetBonus :: !BonusGroupsView -- set bonus newly unlocked at that tier, by category
  , smvCraftable :: !Bool -- not owned, but a learned blueprint can craft it
  , smvTransmutable :: !Bool -- not owned, no blueprint of its own, but the set
                             -- has excess copies elsewhere or a blueprint for
                             -- any member, so a re-rolled transmute can produce it
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetMemberView where toJSON = genericToJSON opts

-- | Stat bonuses split into the same categories as a 'GearView', so the client
-- can fold set bonuses into the per-type resistance/stat aggregates correctly
-- (resistances share the @"N% Type"@ shape with % damage and mustn't be merged).
data BonusGroupsView = BonusGroupsView
  { bgResistBonuses :: ![Text]
  , bgDamageBonuses :: ![Text]
  , bgBonuses :: ![Text]
  , bgSkillBonuses :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON BonusGroupsView where toJSON = genericToJSON opts

emptyBonusGroups :: BonusGroupsView
emptyBonusGroups = BonusGroupsView [] [] [] []

data HoldingView = HoldingView
  { hvLocation :: !Text
  , hvCount :: !Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON HoldingView where toJSON = genericToJSON opts

-- | Set-completion views. @craftableNames@ are the item record basenames a
-- learned blueprint can craft, so unowned members get flagged 'smvCraftable'.
setsView :: GameDb -> [Text] -> [OwnedItem] -> [SetView]
setsView db craftableNames owned = map (toSetView db craftSet) (setReport db owned)
  where
    craftSet = HM.fromList [(n, ()) | n <- craftableNames] :: HM.HashMap Text ()

toSetView :: GameDb -> HM.HashMap Text () -> SetCompletion -> SetView
toSetView db craftSet sc =
  SetView
    { svName = scName sc
    , svRecord = scRecord sc
    , svOwnedCount = scOwnedCount sc
    , svTotal = scTotal sc
    , svComplete = scComplete sc
    , svLevel = case [l | Just l <- map (gvLevelRequirement . smvGear) members] of
        [] -> Nothing
        ls -> Just (maximum ls)
    , svMembers = members
    }
  where
    setRec = lookupRecord (scRecord sc) db
    members = zipWith (toMemberView db craftSet setRec setTransmutable) [1 ..] (scMembers sc)
    -- Transmutation sacrifices any copy of a set item for a random other item
    -- from the same set, so a spare copy of ANY member, or a learned blueprint
    -- for ANY member (owned or not, since you can just craft one), makes every
    -- missing member in the set transmute-eligible.
    setTransmutable =
      sum (map smCount (scMembers sc)) > length (filter smOwned (scMembers sc))
        || any (\mm -> HM.member (smRecord mm) craftSet) (scMembers sc)

toMemberView :: GameDb -> HM.HashMap Text () -> Maybe Record -> Bool -> Int -> SetMember -> SetMemberView
toMemberView db craftSet setRec setTransmutable tier m =
  SetMemberView
    { smvName = smName m
    , smvRecord = smRecord m
    , smvOwned = smOwned m
    , smvCount = smCount m
    , smvHoldings = [HoldingView loc n | (loc, n) <- smHoldings m]
    , smvGear = toGearView (smRecord m) Nothing Nothing (itemAttrs (itemWithName (smRecord m)) db)
    , smvSetTier = tier
    , smvSetBonus = maybe emptyBonusGroups (tierBonusGroups db tier) setRec
    , smvCraftable = craftableFlag
    , smvTransmutable = not (smOwned m) && setTransmutable && not craftableFlag
    }
  where
    craftableFlag = not (smOwned m) && HM.member (smRecord m) craftSet

-- | The set bonus newly unlocked at @tier@ pieces: the per-tier delta of the set
-- record's (cumulative) bonus arrays, so the N-th item shows what the N-piece
-- bonus adds — mirroring the game's "(N)" set-bonus lines — split by category.
tierBonusGroups :: GameDb -> Int -> Record -> BonusGroupsView
tierBonusGroups db tier r =
  let related = [("", deltaTier tier r)]
   in BonusGroupsView
        { bgResistBonuses = resistBonuses related
        , bgDamageBonuses = damageBonuses related
        , bgBonuses = characterBonuses related
        , bgSkillBonuses = skillBonuses db related
        }

-- | Reduce a set record to only what changes at @tier@: each array bonus field
-- becomes its (value@tier − value@tier-1) increment (dropped when unchanged),
-- string fields (e.g. granted-skill names) pass through, everything else drops.
deltaTier :: Int -> Record -> Record
deltaTier tier = HM.mapMaybe pick
  where
    pick (VList xs)
      | not (null xs) =
          let d = numAt (tier - 1) xs - numAt (tier - 2) xs
           in if d /= 0 then Just (VFloat (realToFrac d)) else Nothing
    pick s@(VString _) = Just s
    pick _ = Nothing
    numAt i xs
      | i < 0 = 0
      | otherwise = num (xs !! min i (length xs - 1))
    num (VInt n) = fromIntegral n :: Double
    num (VFloat f) = realToFrac f
    num _ = 0

--------------------------------------------------------------------------------
-- Characters
--------------------------------------------------------------------------------

data CharacterSummaryView = CharacterSummaryView
  { csvName :: !Text
  , csvLevel :: !Int
  , csvClassName :: !Text
  , csvHardcore :: !Bool
  , csvEquippedCount :: !Int
  , csvEquippedSetPieces :: !Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON CharacterSummaryView where toJSON = genericToJSON opts

data CharacterDetailView = CharacterDetailView
  { cdvName :: !Text
  , cdvLevel :: !Int
  , cdvClassName :: !Text
  , cdvHardcore :: !Bool
  , cdvSummary :: !StatSummaryView -- resistances, attributes, key totals
  , cdvAttacks :: ![AttackView] -- per-attack/proc DPS estimate
  , cdvGear :: ![GearView]
  , cdvArmorTable :: ![NamedValueView] -- armor rating per slot (head…feet), ordered by slot
  , cdvShopping :: ![ShoppingView] -- components/augments selected that aren't on the saved character
  , cdvMasteries :: ![MasteryView] -- invested mastery bars + skills
  , cdvDevotions :: ![ConstellationView] -- taken devotion constellations
  }
  deriving (Show, Eq, Generic)

instance ToJSON CharacterDetailView where toJSON = genericToJSON opts

-- | A component/augment the current configuration needs but the saved character
-- doesn't have, with a best-effort source (faction vendor) hint.
data ShoppingView = ShoppingView
  { shopRecord :: !Text
  , shopName :: !Text
  , shopKind :: !Text -- "component" | "augment"
  , shopSource :: !(Maybe Text) -- faction/shop hint, when known
  , shopStanding :: !(Maybe Text) -- minimum faction standing required (augments only)
  , shopCount :: !Int
  , shopSlots :: ![Text] -- gear slot type for each instance (e.g. ["ring", "waist"])
  }
  deriving (Show, Eq, Generic)

instance ToJSON ShoppingView where toJSON = genericToJSON opts

-- | A single invested skill within a mastery.
data SkillEntryView = SkillEntryView
  { sevName :: !Text
  , sevRank :: !Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON SkillEntryView where toJSON = genericToJSON opts

-- | A mastery bar with its invested rank and all skills the character has
-- put points into within that mastery.
data MasteryView = MasteryView
  { mastName :: !Text
  , mastRank :: !Int
  , mastSkills :: ![SkillEntryView]
  }
  deriving (Show, Eq, Generic)

instance ToJSON MasteryView where toJSON = genericToJSON opts

-- | One completed (or partial) devotion constellation: its display name, how
-- many stars are taken, the name of the granted celestial power (if any), and
-- the aggregate stat bonuses from the taken passive stars.
data ConstellationView = ConstellationView
  { conName :: !Text
  , conStars :: !Int
  , conPower :: !(Maybe Text)
  , conBonuses :: !BonusGroupsView
  }
  deriving (Show, Eq, Generic)

instance ToJSON ConstellationView where toJSON = genericToJSON opts

-- | The character's effective stats (gear + devotions + mastery + always-on
-- buffs), folded for the difficulty noted in @ssvDifficulty@.
data StatSummaryView = StatSummaryView
  { ssvDifficulty :: !Text
  , ssvResists :: ![ResistView]
  , ssvAttributes :: ![NamedValueView] -- Physique/Cunning/Spirit absolute totals
  , ssvKeyTotals :: ![KeyTotalView] -- OA, DA, Armor, ... (contribution figures)
  , ssvHealth :: !Double -- computed max Health total
  , ssvEnergy :: !Double -- computed max Energy total
  , ssvOa :: !Double -- computed OA total
  , ssvDa :: !Double -- computed DA total
  , ssvDamage :: ![Text] -- total damage bonuses (e.g. "+120% Acid")
  , ssvDamageTable :: ![DamageRowView] -- per-damage-type table
  , ssvCcResists :: ![ResistView] -- armor absorption + CC resists (with caps/overcap)
  , ssvResistReduction :: ![ResistReductionView] -- resistance reduction applied to enemies
  }
  deriving (Show, Eq, Generic)

instance ToJSON StatSummaryView where toJSON = genericToJSON opts

-- | One resistance-reduction effect: the source that grants it (for hover
-- lookups against the skill dictionary) and the rendered effect text (e.g.
-- @"-30% Total (20% chance, 5s)"@ — see 'resistReductionLines').
data ResistReductionView = ResistReductionView
  { rrvSource :: !Text
  , rrvEffect :: !Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ResistReductionView where toJSON = genericToJSON opts

-- | One row of the per-damage-type breakdown shown in the summary card.
-- DoT flat values are per-second (sum of each source's total/duration).
data DamageRowView = DamageRowView
  { drvType :: !Text
  , drvInstFlatLo :: !Double
  , drvInstFlatHi :: !Double
  , drvInstPct :: !Double
  , drvDotFlatLo :: !Double
  , drvDotFlatHi :: !Double
  , drvDotPct :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON DamageRowView where toJSON = genericToJSON opts

data ResistView = ResistView
  { rvName :: !Text
  , rvValue :: !Double -- effective % after the difficulty penalty
  , rvCap :: !Double
  , rvOvercap :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON ResistView where toJSON = genericToJSON opts

data NamedValueView = NamedValueView
  { nvLabel :: !Text
  , nvValue :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON NamedValueView where toJSON = genericToJSON opts

data KeyTotalView = KeyTotalView
  { ktLabel :: !Text
  , ktFlat :: !Double
  , ktPct :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON KeyTotalView where toJSON = genericToJSON opts

-- | One estimated attack or proc: per-hit and per-second damage with the
-- per-type breakdown, mirroring the @dps@ CLI command.
data AttackView = AttackView
  { avName :: !Text
  , avRank :: !(Maybe Int)
  , avKind :: !Text -- "active" (pick one) or "proc" (auto while attacking)
  , avPerHit :: !Double
  , avDps :: !Double
  , avRate :: !Text
  , avTypes :: ![NamedValueView] -- per damage-type per-hit contribution
  }
  deriving (Show, Eq, Generic)

instance ToJSON AttackView where toJSON = genericToJSON opts

data GearView = GearView
  { gvName :: !Text
  , gvRecord :: !Text -- item record, for the icon endpoint
  , gvType :: !(Maybe Text)
  , gvClassification :: !(Maybe Text)
  , gvLevelRequirement :: !(Maybe Int)
  , gvResistBonuses :: ![Text]
  , gvDamageBonuses :: ![Text]
  , gvBonuses :: ![Text]
  , gvSkillBonuses :: ![Text]
  , gvIsSet :: !Bool
  , gvSetRecord :: !(Maybe Text)
  , gvBitmap :: !(Maybe Text) -- texture path within the asset archive
  , gvComponent :: !(Maybe Text) -- attached component record, if any
  , gvAugment :: !(Maybe Text) -- attached augment record, if any
  }
  deriving (Show, Eq, Generic)

instance ToJSON GearView where toJSON = genericToJSON opts

summaryView :: GameDb -> Character -> CharacterSummaryView
summaryView db c =
  CharacterSummaryView
    { csvName = charName c
    , csvLevel = fromIntegral (charLevel c)
    , csvClassName = className db c
    , csvHardcore = charHardcore c
    , csvEquippedCount = length attrs
    , csvEquippedSetPieces = length (filter iaIsSet attrs)
    }
  where
    attrs = map (`itemAttrs` db) (equippedItems c)

-- | A what-if substitution of an equipped item's base, component, and/or
-- augment, addressed by its index into the (non-empty) equipped-gear list.
-- 'Nothing' keeps the original; @Just ""@ clears the slot/component/augment;
-- @Just record@ swaps in that record. When 'goItem' is set, the slot's saved
-- component\/augment are inherited (overridable via 'goComponent'/'goAugment').
data GearOverride = GearOverride
  { goIndex :: !Int
  , goItem :: !(Maybe Text)
  , goComponent :: !(Maybe Text)
  , goAugment :: !(Maybe Text)
  }
  deriving (Show, Eq)

detailView :: GameDb -> [OwnedItem] -> [GearOverride] -> Difficulty -> Character -> CharacterDetailView
detailView db owned overrides difficulty c =
  CharacterDetailView
    { cdvName = charName c
    , cdvLevel = fromIntegral (charLevel c)
    , cdvClassName = className db c
    , cdvHardcore = charHardcore c
    , cdvSummary =
        (toSummaryView difficulty (statSummary difficulty c (plainSources sources)))
          { ssvResistReduction = [ResistReductionView src eff | (src, eff) <- resistReductionLines db items c]
          }
    , cdvAttacks = map toAttackView (attackDps db sources c)
    , cdvGear = map gearViewOf items
    , cdvArmorTable = armorTable items
    , cdvShopping = shoppingList db c owned (map slotTypeOf items) (equippedItems c) items
    , cdvMasteries = buildMasteries db c
    , cdvDevotions = buildDevotions db c
    }
  where
    -- The effective equipped set after applying any component/augment overrides;
    -- both the stat sources and the gear cards are built from it so they agree.
    items = applyOverrides db overrides (equippedItems c)
    gearViewOf it = toGearView (itemBaseName it) (nonEmpty (itemRelicName it)) (nonEmpty (itemAugmentName it)) (itemAttrs it db)
    slotTypeOf it = iaType (itemAttrs it db)
    -- Effective stat sources, mirroring the `character`/`dps` CLI commands and
    -- folding in always-on (permanent) buffs.  Difficulty is supplied by the
    -- caller; Ultimate is the canonical end-game view (its -50% resist penalty
    -- makes the resist check meaningful) but Normal/Elite are useful when
    -- planning a lower-level character.
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db items ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sources = statSources db items ++ extra
    armorSlotLabels =
      [ ("head", "Head"), ("shoulders", "Shoulders"), ("chest", "Chest")
      , ("hands", "Arms"), ("legs", "Legs"), ("feet", "Feet")
      ]
    pieceArmor it = sumField (plainSources (statSources db [it])) "defensiveProtection"
    -- Global % armor modifier (from all gear + devotions + skills).
    globalArmorPct = sumField (plainSources sources) "defensiveProtectionModifier"
    -- Per-slot armor in GD = (this piece's flat armor + the flat armor every
    -- other source contributes to that body part) * (1 + % armor). The "other"
    -- flat armor is everything except the six displayed body pieces: belt,
    -- jewelry, weapon/shield, relic, components, skills and devotions all add
    -- armor that protects each body part.
    armorTable its =
      let displayed = map fst armorSlotLabels
          globalFlat =
            sumField (plainSources sources) "defensiveProtection"
              - sum [pieceArmor it | it <- its, iaType (itemAttrs it db) `elem` map Just displayed]
       in [ NamedValueView label ((pieceArmor it + globalFlat) * (1 + globalArmorPct / 100))
          | (slotKey, label) <- armorSlotLabels
          , it <- its
          , iaType (itemAttrs it db) == Just slotKey
          ]

nonEmpty :: Text -> Maybe Text
nonEmpty t = if T.null t then Nothing else Just t

-- | Apply gear overrides (base item, component, augment) by position. When a
-- base item is swapped, the original slot's component/augment are inherited
-- before any explicit component/augment overrides are applied on top.
applyOverrides :: GameDb -> [GearOverride] -> [Item] -> [Item]
applyOverrides _db overrides = zipWith apply [0 ..]
  where
    byIndex = HM.fromList [(goIndex o, o) | o <- overrides]
    apply i it = maybe it (`applyOverride` it) (HM.lookup i byIndex)
    applyOverride o it =
      let swapped = case goItem o of
            Just newRec | not (T.null newRec) -> inheritGear it (itemWithName newRec)
            _ -> it
       in swapped
            { itemRelicName = fromMaybe (itemRelicName swapped) (goComponent o)
            , itemAugmentName = fromMaybe (itemAugmentName swapped) (goAugment o)
            }

-- | The components/augments/items the effective build uses that the saved
-- character does not (counted). Augments include a faction-vendor hint;
-- items include a location hint (which character/stash holds the candidate).
shoppingList :: GameDb -> Character -> [OwnedItem] -> [Maybe Text] -> [Item] -> [Item] -> [ShoppingView]
shoppingList db c owned slots origs effs =
  [ toShop kind rec [s | (k, r, s) <- changes, k == kind, r == rec]
  | (kind, rec) <- nub [(k, r) | (k, r, _) <- changes]
  ]
  where
    shopMap = buildFactionShopMap (gdbRecords db)
    changes = concat (zipWith3 diff slots origs effs)
    diff slot o e =
      let itemChanged = not (T.null (itemBaseName e)) && itemBaseName e /= itemBaseName o
       in [("item", r, slot) | let r = itemBaseName e, not (T.null r), r /= itemBaseName o]
            ++ [("component", r, slot) | let r = itemRelicName e, not (T.null r), r /= itemRelicName o || itemChanged]
            ++ [("augment", r, slot) | let r = itemAugmentName e, not (T.null r), r /= itemAugmentName o || itemChanged]
    nameForItem rec =
      let attrs = itemAttrs (itemWithName rec) db
       in iaDisplayName attrs
    locationForItem rec =
      case [oiLocation oi | oi <- owned, itemBaseName (oiItem oi) == rec] of
        (loc : _) -> Just (locationLabel loc)
        [] -> Nothing
    toShop kind rec slotList =
      let (src, standing) = case kind of
            "augment" -> case HM.lookup rec shopMap of
              Just (faction, tier) -> (Just faction, Just tier)
              Nothing -> (augmentFaction db rec, Nothing)
            "item" -> (locationForItem rec, Nothing)
            _ -> (Nothing, Nothing)
       in ShoppingView
            { shopRecord = rec
            , shopName = case kind of
                "item" -> nameForItem rec
                _ -> fromMaybe (T.takeWhileEnd (/= '/') rec) (lookupRecord rec db >>= HM.lookup "description" >>= valueText)
            , shopKind = kind
            , shopSource = src
            , shopStanding = standing
            , shopCount = length slotList
            , shopSlots = [s | Just s <- slotList]
            }

-- | Build mastery groups from the character's skill list. Each mastery bar
-- becomes a 'MasteryView' with its invested rank and the skills the character
-- has put points into within that mastery.
buildMasteries :: GameDb -> Character -> [MasteryView]
buildMasteries db c = map renderMastery masteryBars
  where
    classSkills = [s | s <- charSkills c, "records/skills/playerclass" `T.isPrefixOf` skName s]
    masteryBars = [s | s <- classSkills, "_classtraining_" `T.isInfixOf` skName s]
    normalSkills = [s | s <- classSkills, not ("_classtraining_" `T.isInfixOf` skName s), skLevel s > 0]
    renderMastery bar =
      MasteryView
        { mastName = skillDisplayName db (skName bar)
        , mastRank = fromIntegral (skLevel bar)
        , mastSkills =
            [ SkillEntryView (skillDisplayName db (skName s)) (fromIntegral (skLevel s))
            | s <- normalSkills
            , classSegment (skName s) == classSegment (skName bar)
            ]
        }
    classSegment p = case filter ("playerclass" `T.isPrefixOf`) (T.splitOn "/" p) of
      (x : _) -> x
      [] -> ""

-- | Build constellation views from the character's devotion stars.
buildDevotions :: GameDb -> Character -> [ConstellationView]
buildDevotions db c = map renderConstellation constellations
  where
    devStars = [s | s <- charSkills c, "/devotion/tier" `T.isInfixOf` skName s]
    constKey s =
      let leaf = last (T.splitOn "/" (skName s))
          base = T.dropEnd 4 leaf
       in case T.splitOn "_" base of
            (a : b : _) -> a <> "_" <> T.takeWhile isDigit b
            _ -> base
    isPower s = "_skill" `T.isSuffixOf` T.dropEnd 4 (last (T.splitOn "/" (skName s)))
    constellations = foldl (\acc s -> if constKey s `elem` acc then acc else acc ++ [constKey s]) [] devStars
    renderConstellation k =
      let grp = [s | s <- devStars, constKey s == k]
          passives = filter (not . isPower) grp
          name = case passives of
            (s : _) -> skillDisplayName db (skName s)
            [] -> maybe "?" (skillDisplayName db . skName) (listToMaybe grp)
          power = listToMaybe (nub [skillDisplayName db (skName s) | s <- grp, isPower s])
          related = [(skName s, r) | s <- passives, Just r <- [lookupRecord (skName s) db]]
          grantedSkills = ["Grants " <> p | Just p <- [power]]
       in ConstellationView
            { conName = name
            , conStars = length grp
            , conPower = Nothing
            , conBonuses = BonusGroupsView
                { bgResistBonuses = resistBonuses related
                , bgDamageBonuses = damageBonuses related
                , bgBonuses = characterBonuses related
                , bgSkillBonuses = grantedSkills ++ skillBonuses db related
                }
            }

-- | Map reputation value to in-game standing tier name.
-- In-game order (lowest→highest positive): Friendly < Respected < Honored < Revered.
-- Thresholds: Friendly 1500, Respected 5000, Honored 10000, Revered 25000 (cap).
standingTierOf :: Float -> Text
standingTierOf v
  | v >= 25000 = "Revered"
  | v >= 10000 = "Honored"
  | v >= 5000  = "Respected"
  | v >= 1500  = "Friendly"
  | otherwise  = ""

standingRank :: Text -> Int
standingRank "Friendly"  = 1
standingRank "Respected" = 2
standingRank "Honored"   = 3
standingRank "Revered"   = 4
standingRank _           = 0

-- | Map from faction display name → current standing tier for this character.
-- Block 13 stores factions 1-based: index 1 = Devil's Crossing, indices 7+
-- correspond to UserN where N = i-7 (empirically determined: User0=Rovers at
-- i=7 gives 25000 max-rep, User7=Black Legion at i=14 gives 24600 Honored,
-- User8=Kymon's at i=15 gives 14749 Honored — all consistent with a
-- full-play character; offset=6 gave Rovers/Black Legion/Malmouth as hostile
-- which is clearly wrong).
buildCharFactionStandings :: GameDb -> Character -> HM.HashMap Text Text
buildCharFactionStandings db c =
  HM.fromList
    [ (name, tier)
    | (i, val) <- zip [1 ..] (charFactions c)
    , Just name <- [factionNameByIndex i]
    , let tier = standingTierOf val
    , not (T.null tier)
    ]
  where
    factionNameByIndex 1 = Just "Devil's Crossing"
    factionNameByIndex i
      | i >= 7 = factionName ("User" <> T.pack (show (i - 7)))
    factionNameByIndex _ = Nothing

-- | Map from augment record name → (faction display name, minimum standing tier).
-- Built from the factiontable merchant records in the ARZ; authoritative over
-- the factionSource heuristic since it includes the required standing tier.
buildFactionShopMap :: RecordDb -> HM.HashMap Text (Text, Text)
buildFactionShopMap recs =
  HM.fromList
    [ (item, (factionKeyName fkey, capitalise tier))
    | (nm, r) <- HM.toList recs
    , "factiontables/" `T.isInfixOf` nm
    , not ("_merchanttbl" `T.isPrefixOf` T.takeWhileEnd (/= '/') nm)
    , Just (fkey, tier) <- [parseFT nm]
    , Just (VList items) <- [HM.lookup "marketStaticItems" r]
    , VString item <- items
    ]
  where
    parseFT nm =
      let base = T.dropEnd 4 (T.takeWhileEnd (/= '/') nm)
       in case T.splitOn "_" base of
            (fkey : tier : _) -> Just (fkey, tier)
            _ -> Nothing
    capitalise t = T.toUpper (T.take 1 t) <> T.drop 1 t
    factionKeyName k = case k of
      "bysmiel"          -> "Cult of Bysmiel"
      "blacklegion"      -> "The Black Legion"
      "dreeg"            -> "Cult of Dreeg"
      "devilscrossing"   -> "Devil's Crossing"
      "orderdeathsvigil" -> "Order of Death's Vigil"
      "malmouth"         -> "Malmouth Resistance"
      "kymonchosen"      -> "Kymon's Chosen"
      "coven"            -> "Coven of Ugdenbog"
      "solael"           -> "Cult of Solael"
      "exile"            -> "The Outcast"
      "wendigo"          -> "Barrowholm"
      "rovers"           -> "Rovers"
      "homestead"        -> "Homestead"
      _                  -> k

augmentFaction :: GameDb -> Text -> Maybe Text
augmentFaction db rec =
  (lookupRecord rec db >>= HM.lookup "factionSource" >>= valueText) >>= factionName

-- Faction-vendor names for the augment @factionSource@ enum. There is NO
-- authoritative enum->faction mapping in the game data, so this is built by
-- inference from the augments each source sells. Two classes of confidence:
--   * name-matched (high): the augments literally name the faction — User4
--     "Outcast's …", User8 "Kymon's …", User9 "Coven's …", User11 "Malmouth's …",
--     User13 "Bysmiel's …", User14 "Dreeg's …", User15 "Solael's …", User10
--     (Ravager/Wendigo = Barrowholm), User5 (Uroboruuk = Order of Death's Vigil).
--   * user-confirmed: User0 = Rovers (Nightshade Powder), User7 = The Black Legion
--     (Kingsguard Powder), "Survivors" = Devil's Crossing.
-- User2 = Homestead: its augments (Menhir's Blessing, Beast Tamer's, Solar
-- Radiance) are all Homestead faction augments per grimtools/wiki. (An earlier
-- "Black Legion" guess for User2 was wrong.)
factionName :: Text -> Maybe Text
factionName src = case src of
  "Survivors" -> Just "Devil's Crossing"
  "User0" -> Just "Rovers"
  "User2" -> Just "Homestead"
  "User4" -> Just "The Outcast"
  "User5" -> Just "Order of Death's Vigil"
  "User7" -> Just "The Black Legion"
  "User8" -> Just "Kymon's Chosen"
  "User9" -> Just "Coven of Ugdenbog"
  "User10" -> Just "Barrowholm"
  "User11" -> Just "Malmouth Resistance"
  "User13" -> Just "Cult of Bysmiel"
  "User14" -> Just "Cult of Dreeg"
  "User15" -> Just "Cult of Solael"
  _
    | "User" `T.isPrefixOf` src -> Nothing -- unconfirmed faction enum (e.g. User2)
    | T.null src -> Nothing
    | otherwise -> Just src -- already a readable faction name

toSummaryView :: Difficulty -> StatSummary -> StatSummaryView
toSummaryView diff s =
  StatSummaryView
    { ssvDifficulty = case diff of Normal -> "Normal"; Elite -> "Elite"; Ultimate -> "Ultimate"
    , ssvResists = [ResistView n v cap over | (n, v, cap, over) <- ssResists s]
    , ssvAttributes = [NamedValueView l v | (l, v) <- ssAttributes s]
    , ssvKeyTotals =
        [ KeyTotalView l flat pct
        | (l, flat, pct) <- ssKeyTotals s
        , l `notElem` ["Health", "Energy"] -- shown as totals below, not contributions
        ]
    , ssvHealth = ssHealthTotal s
    , ssvEnergy = ssEnergyTotal s
    , ssvOa = ssOaTotal s
    , ssvDa = ssDaTotal s
    , ssvDamage = ssDamage s
    , ssvDamageTable = map toDamageRowView (ssDamageTable s)
    , ssvCcResists = [ResistView n v cap over | (n, v, cap, over) <- ssCcResists s]
    , ssvResistReduction = [] -- set by detailView, which has the item/skill data this needs
    }

toDamageRowView :: DamageRow -> DamageRowView
toDamageRowView r =
  DamageRowView
    { drvType = drType r
    , drvInstFlatLo = fst (drInstFlat r)
    , drvInstFlatHi = snd (drInstFlat r)
    , drvInstPct = drInstPct r
    , drvDotFlatLo = fst (drDotFlat r)
    , drvDotFlatHi = snd (drDotFlat r)
    , drvDotPct = drDotPct r
    }

toAttackView :: AttackDps -> AttackView
toAttackView a =
  AttackView
    { avName = adName a
    , avRank = adRank a
    , avKind = case adKind a of Active -> "active"; Triggered -> "proc"
    , avPerHit = adPerHit a
    , avDps = adDps a
    , avRate = adRate a
    , avTypes = [NamedValueView t d | (t, d) <- adTypes a]
    }

-- | JSON text for a 'SourceCategory', plus the one synthetic value
-- ("retaliation") used only for the "Retaliation added to attack" flat line
-- within a 'TypeBreakdownView' (see 'retaliationPseudoSource') — not a real
-- 'SourceCategory' constructor, since it's a computed aggregate of several
-- real sources, not one source.
type SourceCategoryView = Text

sourceCategoryView :: Source -> SourceCategoryView
sourceCategoryView s
  | s == retaliationPseudoSource = "retaliation"
  | otherwise = case srcCategory s of
      SrcGear -> "gear"
      SrcComponent -> "component"
      SrcAugment -> "augment"
      SrcSetBonus -> "setBonus"
      SrcDevotion -> "devotion"
      SrcMastery -> "mastery"
      SrcSkill -> "skill"
      SrcOther -> "other"

data SourceContributionView = SourceContributionView
  { scvLabel :: !Text
  , scvCategory :: !SourceCategoryView
  , scvValue :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON SourceContributionView where toJSON = genericToJSON opts

toContributionView :: SourceAmount -> SourceContributionView
toContributionView sa = SourceContributionView (srcLabel (saSource sa)) (sourceCategoryView (saSource sa)) (saValue sa)

data SourceImpactView = SourceImpactView
  { sivLabel :: !Text
  , sivCategory :: !SourceCategoryView
  , sivDpsImpact :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON SourceImpactView where toJSON = genericToJSON opts

toImpactView :: SourceImpact -> SourceImpactView
toImpactView si = SourceImpactView (srcLabel (siSource si)) (sourceCategoryView (siSource si)) (siDpsImpact si)

data TypeBreakdownView = TypeBreakdownView
  { tbvLabel :: !Text
  , tbvTotal :: !Double
  , tbvFlat :: ![SourceContributionView]
  , tbvFlatSubtotal :: !Double
  , tbvPercent :: ![SourceContributionView]
  , tbvTotalPercent :: !Double
  , tbvDurationPercent :: ![SourceContributionView]
  , tbvTotalDurationPercent :: !Double
  , tbvDamagePercent :: ![SourceContributionView]
  , tbvTotalDamagePercent :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON TypeBreakdownView where toJSON = genericToJSON opts

toTypeBreakdownView :: TypeDetail -> TypeBreakdownView
toTypeBreakdownView t =
  TypeBreakdownView
    { tbvLabel = tdLabel t
    , tbvTotal = tdTotal t
    , tbvFlat = map toContributionView (tdFlatSources t)
    , tbvFlatSubtotal = tdFlatSubtotal t
    , tbvPercent = map toContributionView (tdPercentSources t)
    , tbvTotalPercent = tdTotalPercent t
    , tbvDurationPercent = map toContributionView (tdDurationSources t)
    , tbvTotalDurationPercent = tdTotalDurationPercent t
    , tbvDamagePercent = map toContributionView (tdDamagePctSources t)
    , tbvTotalDamagePercent = tdTotalDamagePercent t
    }

data RetaliationTypeBreakdownView = RetaliationTypeBreakdownView
  { rtbvLabel :: !Text
  , rtbvFlat :: ![SourceContributionView]
  , rtbvFlatSubtotal :: !Double
  , rtbvPercent :: ![SourceContributionView]
  , rtbvTotalPercent :: !Double
  , rtbvRetaliationDamage :: !Double
  , rtbvAddedToAttack :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON RetaliationTypeBreakdownView where toJSON = genericToJSON opts

toRetaliationTypeView :: RetaliationTypeDetail -> RetaliationTypeBreakdownView
toRetaliationTypeView t =
  RetaliationTypeBreakdownView
    { rtbvLabel = rtdLabel t
    , rtbvFlat = map toContributionView (rtdFlatSources t)
    , rtbvFlatSubtotal = rtdFlatSubtotal t
    , rtbvPercent = map toContributionView (rtdPercentSources t)
    , rtbvTotalPercent = rtdTotalPercent t
    , rtbvRetaliationDamage = rtdRetaliationDamage t
    , rtbvAddedToAttack = rtdAddedToAttack t
    }

data RetaliationBreakdownView = RetaliationBreakdownView
  { rbvAddToAttackPct :: ![SourceContributionView]
  , rbvTotalAddToAttackPct :: !Double
  , rbvByType :: ![RetaliationTypeBreakdownView]
  }
  deriving (Show, Eq, Generic)

instance ToJSON RetaliationBreakdownView where toJSON = genericToJSON opts

toRetaliationView :: RetaliationDetail -> RetaliationBreakdownView
toRetaliationView rd =
  RetaliationBreakdownView
    { rbvAddToAttackPct = map toContributionView (rdAddToAttackSources rd)
    , rbvTotalAddToAttackPct = rdTotalAddToAttackPct rd
    , rbvByType = map toRetaliationTypeView (rdByType rd)
    }

data RateFactorView = RateFactorView
  { rfvLabel :: !Text
  , rfvBase :: !Double
  , rfvContributions :: ![SourceContributionView]
  , rfvEffective :: !Double
  , rfvFormula :: !Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RateFactorView where toJSON = genericToJSON opts

toRateFactorView :: RateFactorDetail -> RateFactorView
toRateFactorView r = RateFactorView (rfdLabel r) (rfdBase r) (map toContributionView (rfdSources r)) (rfdEffective r) (rfdFormula r)

data TriggerView = TriggerView
  { trvChancePct :: !Double
  , trvCooldown :: !Double
  , trvGrantedBy :: !Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TriggerView where toJSON = genericToJSON opts

toTriggerView :: TriggerDetail -> TriggerView
toTriggerView t = TriggerView (trgChancePct t) (trgCooldown t) (trgGrantedBy t)

data AttackBreakdownView = AttackBreakdownView
  { abvName :: !Text
  , abvRank :: !(Maybe Int)
  , abvKind :: !Text
  , abvPerHit :: !Double
  , abvDps :: !Double
  , abvRate :: !Text
  , abvSourcesByImpact :: ![SourceImpactView]
  , abvTypes :: ![TypeBreakdownView]
  , abvRetaliation :: !(Maybe RetaliationBreakdownView)
  , abvRateFactors :: ![RateFactorView]
  , abvTrigger :: !(Maybe TriggerView)
  }
  deriving (Show, Eq, Generic)

instance ToJSON AttackBreakdownView where toJSON = genericToJSON opts

-- | The DPS attribution breakdown for one attack/proc row, identified by
-- name/rank/kind (matching an 'Attack'/'AttackDps' row already shown on the
-- character page). Mirrors 'detailView''s effective-sources construction so
-- the breakdown reflects the same what-if overrides. @difficulty@ is taken
-- for API-shape parity with 'detailView' (the same query params apply to
-- both endpoints) but is otherwise unused here: it only affects the
-- resistance-penalty numbers 'statSummary' computes, not the DPS estimate.
attackBreakdownView
  :: GameDb -> [OwnedItem] -> [GearOverride] -> Difficulty -> Character -> Text -> Maybe Int -> AttackKind -> Maybe AttackBreakdownView
attackBreakdownView db _owned overrides _difficulty c name rank kind =
  toView <$> attackDpsBreakdown db sources c name rank kind
  where
    items = applyOverrides db overrides (equippedItems c)
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db items ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sources = statSources db items ++ extra
    toView bd =
      AttackBreakdownView
        { abvName = abName bd
        , abvRank = abRank bd
        , abvKind = case abKind bd of Active -> "active"; Triggered -> "proc"
        , abvPerHit = abPerHit bd
        , abvDps = abDps bd
        , abvRate = abRate bd
        , abvSourcesByImpact = map toImpactView (abSourcesByImpact bd)
        , abvTypes = map toTypeBreakdownView (abTypes bd)
        , abvRetaliation = toRetaliationView <$> abRetaliation bd
        , abvRateFactors = map toRateFactorView (abRateFactors bd)
        , abvTrigger = toTriggerView <$> abTrigger bd
        }

toGearView :: Text -> Maybe Text -> Maybe Text -> ItemAttrs -> GearView
toGearView record component augment a =
  GearView
    { gvName = iaDisplayName a
    , gvRecord = record
    , gvType = iaType a
    , gvClassification = iaClassification a
    , gvLevelRequirement = iaLevelRequirement a
    , gvResistBonuses = iaResistBonuses a
    , gvDamageBonuses = iaDamageBonuses a
    , gvBonuses = iaBonuses a
    , gvSkillBonuses = iaSkillBonuses a
    , gvIsSet = iaIsSet a
    , gvSetRecord = iaSetRecord a
    , gvBitmap = iaBitmap a
    , gvComponent = component
    , gvAugment = augment
    }

-- The equipment slots a component/augment may declare it fits (boolean fields
-- on the record); the gear `type` maps onto these directly.
slotFlags :: [Text]
slotFlags =
  [ "head", "shoulders", "chest", "hands", "legs", "feet", "waist"
  , "amulet", "medal", "ring", "offhand", "shield"
  , "axe", "axe2h", "dagger", "mace", "mace2h", "ranged1h", "ranged2h", "scepter", "spear2h", "sword", "sword2h"
  ]

-- | A component ('ItemRelic') or augment ('ItemEnchantment') the user can attach.
data EnhancementView = EnhancementView
  { evRecord :: !Text
  , evName :: !Text
  , evClassification :: !(Maybe Text)
  , evLevel :: !(Maybe Int) -- level requirement
  , evSlots :: ![Text]
  , evResistBonuses :: ![Text]
  , evDamageBonuses :: ![Text]
  , evBonuses :: ![Text]
  , evSkillBonuses :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON EnhancementView where toJSON = genericToJSON opts

data CatalogView = CatalogView
  { cvComponents :: ![EnhancementView]
  , cvAugments :: ![EnhancementView]
  }
  deriving (Show, Eq, Generic)

instance ToJSON CatalogView where toJSON = genericToJSON opts

-- | All attachable components and augments, with the slots each allows and the
-- stats it grants — the catalogue the UI filters per slot.
enhancementCatalog :: GameDb -> CatalogView
enhancementCatalog db =
  CatalogView (collect "ItemRelic") (collect "ItemEnchantment")
  where
    collect cls =
      sortOn evName
        [ toEnh r rec
        | (r, rec) <- HM.toList (gdbRecords db)
        , (HM.lookup "Class" rec >>= valueText) == Just cls
        , HM.member "description" rec
        , not (null (enhSlots rec))
        ]
    enhSlots rec = [f | f <- slotFlags, HM.lookup f rec == Just (VInt 1)]
    levelOf rec = case HM.lookup "levelRequirement" rec of
      Just (VInt n) -> Just (fromIntegral n)
      Just (VFloat f) -> Just (round f)
      _ -> Nothing
    toEnh r rec =
      let related = [("", rec)]
       in EnhancementView
            { evRecord = r
            , evName = fromMaybe (T.takeWhileEnd (/= '/') r) (HM.lookup "description" rec >>= valueText)
            , evClassification = HM.lookup "itemClassification" rec >>= valueText
            , evLevel = levelOf rec
            , evSlots = enhSlots rec
            , evResistBonuses = resistBonuses related
            , evDamageBonuses = damageBonuses related
            , evBonuses = characterBonuses related
            , evSkillBonuses = skillBonuses db related
            }

-- | A craftable component or relic and the status of its crafting blueprint.
data CraftableView = CraftableView
  { cbName :: !Text
  , cbRecord :: !Text -- the crafted item record (icon / lookup)
  , cbClassification :: !(Maybe Text) -- rarity tier
  , cbLevel :: !(Maybe Int) -- level requirement of the crafted item
  , cbStatus :: !Text -- "learned" | "default" | "missing"
  , cbBonuses :: !BonusGroupsView -- what the crafted item grants
  }
  deriving (Show, Eq, Generic)

instance ToJSON CraftableView where toJSON = genericToJSON opts

-- | Every item of @craftClass@ (e.g. @"ItemRelic"@ components or @"ItemArtifact"@
-- relics) that has a crafting blueprint, with each item's blueprint status:
--
--   * @learned@ — a @Blueprint:@ recipe the account has in @formulas.gst@.
--   * @default@ — always craftable without finding a blueprint: a bare-name
--     blacksmith recipe, or any recipe whose item level is at most
--     @autoDefaultMax@ (low-level component recipes the game grants for free).
--   * @missing@ — a @Blueprint:@ recipe above that level not yet found.
--
-- @autoDefaultMax@ is the level cutoff for the free low-level recipes (20 for
-- components; 0 for relics, which always require a blueprint).
-- Deduplicated by crafted item (best status wins: learned > default > missing).
craftableBlueprints :: Text -> Int -> GameDb -> [Text] -> [CraftableView]
craftableBlueprints craftClass autoDefaultMax db learnedNames =
  sortOn (\c -> (cbLevel c, cbName c)) (HM.elems byItem)
  where
    learnedSet = HM.fromList [(n, ()) | n <- learnedNames] :: HM.HashMap Text ()
    levelOf rec = case HM.lookup "levelRequirement" rec of
      Just (VInt n) -> Just (fromIntegral n)
      Just (VFloat f) -> Just (round f)
      _ -> Nothing
    bonusesOf rrec =
      let related = [("", rrec)]
       in BonusGroupsView
            { bgResistBonuses = resistBonuses related
            , bgDamageBonuses = damageBonuses related
            , bgBonuses = characterBonuses related
            , bgSkillBonuses = skillBonuses db related
            }
    byItem = HM.fromListWith mergeStatus
      [ ( crafted
        , CraftableView
            { cbName = fromMaybe (T.takeWhileEnd (/= '/') crafted) (HM.lookup "description" rrec >>= valueText)
            , cbRecord = crafted
            , cbClassification = HM.lookup "itemClassification" rrec >>= valueText
            , cbLevel = lvl
            , cbStatus = status
            , cbBonuses = bonusesOf rrec
            }
        )
      | (bpName, bp) <- HM.toList (gdbRecords db)
      , "crafting/blueprints/" `T.isInfixOf` bpName
      , Just crafted <- [HM.lookup "artifactName" bp >>= valueText]
      , Just rrec <- [lookupRecord crafted db]
      , (HM.lookup "Class" rrec >>= valueText) == Just craftClass
      , let desc = fromMaybe "" (HM.lookup "description" bp >>= valueText)
            learnable = "Blueprint:" `T.isPrefixOf` desc
            lvl = levelOf rrec
            status
              | HM.member bpName learnedSet = "learned"
              | not learnable = "default" -- bare-name blacksmith recipe
              | maybe False (<= autoDefaultMax) lvl = "default" -- free low-level recipe
              | otherwise = "missing"
      ]
    rank s = case s :: Text of "learned" -> 2 :: Int; "default" -> 1; _ -> 0
    mergeStatus a b = if rank (cbStatus b) > rank (cbStatus a) then b else a

-- | A skill's tooltip payload: its description plus what it grants (the scalar
-- effects we can read off the skill record — per-level array effects are skipped).
data SkillInfoView = SkillInfoView
  { siDescription :: !Text
  , siBonuses :: !BonusGroupsView
  }
  deriving (Show, Eq, Generic)

instance ToJSON SkillInfoView where toJSON = genericToJSON opts

-- | Map every skill's display name to its tooltip info, for UI hover cards on
-- "Grants X" / "+N to X" skill bonus lines. Deduplicated by display name,
-- preferring an entry that actually has a description.
skillDictionary :: GameDb -> HM.HashMap Text SkillInfoView
skillDictionary db =
  HM.fromListWith prefer
    [ (nm, SkillInfoView desc bonuses)
    | (_, r) <- HM.toList (gdbRecords db)
    , Just nm <- [HM.lookup "skillDisplayName" r >>= valueText]
    , not (T.null nm)
    , let desc = fromMaybe "" (HM.lookup "skillBaseDescription" r >>= valueText)
          bonuses = bonusesOf r
    , not (T.null desc) || not (emptyGroups bonuses)
    ]
  where
    -- Skill effects are stored per-rank as arrays (e.g. @offensiveFireMin =
    -- [12,31,50,…]@); the scalar extractors only read single values, so collapse
    -- each list to its rank-1 entry first. Records that already use scalars
    -- (item-granted skills like relic procs) are unchanged.
    rank1 (VList (x : _)) = x
    rank1 v = v
    bonusesOf r0 =
      let related = [("", HM.map rank1 r0)]
       in BonusGroupsView
            { bgResistBonuses = resistBonuses related
            , bgDamageBonuses = damageBonuses related
            , bgBonuses = characterBonuses related
            , bgSkillBonuses = skillBonuses db related
            }
    emptyGroups b =
      null (bgResistBonuses b)
        && null (bgDamageBonuses b)
        && null (bgBonuses b)
        && null (bgSkillBonuses b)
    prefer a b = if not (T.null (siDescription a)) then a else b

equippedItems :: Character -> [Item]
equippedItems = filter (not . emptyItemName) . charEquipped

-- | Map a gear item's @iaType@ to the enhancement slot-flag that components and
-- augments declare to claim compatibility. Returns 'Nothing' for slots that
-- take no components/augments (relics).
enhancementSlotFlag :: Maybe Text -> Maybe Text
enhancementSlotFlag mt = do
  t <- mt
  case T.toLower t of
    "itemartifact" -> Nothing
    "relic" -> Nothing
    "torso" -> Just "chest"
    "belt" -> Just "waist"
    "neck" -> Just "amulet"
    "necklace" -> Just "amulet"
    s -> Just s

-- | Rank every catalogue enhancement that fits the gear slot at @index@ by the
-- same scoring algorithm as the @upgrades@ CLI, holding every other slot and
-- attachment (including the current overrides) fixed. The @kind@ selects which
-- attachment to vary: @"component"@ swaps the slot's component, anything else
-- swaps the augment. Returns the records in best-first order with the score
-- delta and its components, so the UI can both rank and (optionally) explain.
data RankView = RankView
  { rvRecord :: !Text
  , rvScore :: !Double
  , rvOaDelta :: !Double
  , rvDaDelta :: !Double
  , rvDpsDelta :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON RankView where toJSON = genericToJSON opts

rankEnhancements :: GameDb -> [GearOverride] -> Difficulty -> Int -> Text -> Character -> [RankView]
rankEnhancements db overrides difficulty slot kind c =
  case mFlag of
    Nothing -> []
    Just flag ->
      let cat = enhancementCatalog db
          pool = case kind of
            "component" -> cvComponents cat
            _ -> cvAugments cat
          compatible = [ev | ev <- pool, flag `elem` evSlots ev, canBuy (evRecord ev)]
          scored = [toRank (evRecord ev) (scoreItems sb (substitute (evRecord ev))) | ev <- compatible]
       in sortOn (negate . rvScore) scored
  where
    shopMap = buildFactionShopMap (gdbRecords db)
    charStandings = buildCharFactionStandings db c
    canBuy rec
      | kind /= "augment" = True
      | otherwise = case HM.lookup rec shopMap of
          Just (faction, reqTier) ->
            case HM.lookup faction charStandings of
              Just charTier -> standingRank charTier >= standingRank reqTier
              Nothing -> False
          Nothing -> True
    -- Upgrades are scored against the current build (with the user's what-if
    -- overlays applied), so suggestions reflect the gear as configured.
    baseItems = applyOverrides db overrides (equippedItems c)
    mTarget = case drop slot baseItems of
      (t : _) -> Just t
      [] -> Nothing
    mFlag = mTarget >>= \t -> enhancementSlotFlag (iaType (itemAttrs t db))
    -- match `detailView`'s effective stat sources (caller-chosen difficulty,
    -- permanent buffs)
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db baseItems ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sb :: ScoreBase
    sb = mkScoreBase defaultWeights defaultUpgradeTarget difficulty c extra db baseItems
    -- substitute the candidate record onto the targeted slot's component or augment
    substitute rec =
      zipWith
        (\i it -> if i == slot then setAttachment rec it else it)
        [0 ..]
        baseItems
    setAttachment rec it = case kind of
      "component" -> it {itemRelicName = rec}
      _ -> it {itemAugmentName = rec}
    toRank r (sc, _changes, oa, da, dps) = RankView r sc oa da dps

-- | Ranked candidate items for a given gear slot. Mirrors the @upgrades@ CLI:
-- each owned item of the same slot type is overlaid (inheriting the current
-- slot's component\/augment) and scored against the base build. Returns only
-- candidates that score strictly above the current item, best-first. Locations
-- come from 'loadOwnedItems' (e.g. @"Adam (stash)"@, @"shared stash"@).
data ItemRankView = ItemRankView
  { irvRecord :: !Text
  , irvName :: !Text
  , irvLocation :: !Text
  , irvLevel :: !(Maybe Int)
  , irvClassification :: !(Maybe Text)
  , irvScore :: !Double
  , irvOaDelta :: !Double
  , irvDaDelta :: !Double
  , irvDpsDelta :: !Double
  , irvResistDeltas :: ![Text] -- e.g. "+10% Fire", "-5% Cold"
  }
  deriving (Show, Eq, Generic)

instance ToJSON ItemRankView where toJSON = genericToJSON opts

rankItems :: GameDb -> [OwnedItem] -> [GearOverride] -> Difficulty -> Int -> Character -> [ItemRankView]
rankItems db owned overrides difficulty slot c =
  case mTargetType of
    Nothing -> []
    Just ty ->
      let candidates =
            [ (locationLabel (oiLocation oi), oiItem oi)
            | oi <- owned
            , iaType (itemAttrs (oiItem oi) db) == Just ty
            ]
          -- One candidate per display name (the user picks an *item*, not a
          -- copy of it); keep the first location encountered.
          dedup = nubBy (\(_, a) (_, b) -> dn a == dn b) candidates
          -- Skip the item in this slot (score 0) and any item already equipped
          -- in another slot of the same type (e.g. the other ring).
          currentName = maybe "" dn mTarget
          otherSlotNames =
            [ dn it
            | (i, it) <- zip [0 ..] baseItems
            , i /= slot
            , iaType (itemAttrs it db) == Just ty
            ]
          excluded n = n == currentName || n `elem` otherSlotNames
          scored = [score loc cand | (loc, cand) <- dedup, not (excluded (dn cand))]
       in sortOn (negate . irvScore) [r | r <- scored, irvScore r > 0]
  where
    dn it = iaDisplayName (itemAttrs it db)
    -- Score against the current build (with the user's what-if overlays applied).
    baseItems = applyOverrides db overrides (equippedItems c)
    (mTarget, mTargetType) = case drop slot baseItems of
      (t : _) -> (Just t, iaType (itemAttrs t db))
      [] -> (Nothing, Nothing)
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db baseItems ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sb :: ScoreBase
    sb = mkScoreBase defaultWeights defaultUpgradeTarget difficulty c extra db baseItems
    score loc cand =
      let target = case mTarget of
            Just t -> t
            Nothing -> cand -- unreachable; mTargetType would be Nothing too
          swapped = replaceAt slot (inheritGear target cand) baseItems
          (sc, changes, oa, da, dps) = scoreItems sb swapped
          attrs = itemAttrs cand db
          fmtDelta (n, b, a) =
            let d = a - b
                sign = if d >= 0 then "+" else ""
             in sign <> T.pack (show (round d :: Int)) <> "% " <> n
       in ItemRankView
            (itemBaseName cand)
            (iaDisplayName attrs)
            loc
            (iaLevelRequirement attrs)
            (iaClassification attrs)
            sc
            oa
            da
            dps
            (map fmtDelta changes)
    replaceAt i x xs =
      let (before, rest) = splitAt i xs
       in case rest of
            (_ : after) -> before ++ x : after
            [] -> before ++ [x]

-- localized class display name, falling back to the raw tag
className :: GameDb -> Character -> Text
className db c = HM.lookupDefault (charClassName c) (charClassName c) (gdbText db)
