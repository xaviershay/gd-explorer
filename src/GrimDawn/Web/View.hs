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
  , ResistView (..)
  , NamedValueView (..)
  , KeyTotalView (..)
  , AttackView (..)
  , EnhancementView (..)
  , CatalogView (..)
  , ShoppingView (..)
  , GearOverride (..)
  , setsView
  , summaryView
  , detailView
  , enhancementCatalog
  , rankEnhancements
  ) where

import Data.Aeson (Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Char (isUpper, toLower)
import qualified Data.HashMap.Strict as HM
import Data.List (nub, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import GrimDawn.Aggregate (OwnedItem)
import GrimDawn.Arz (Record, Value (..), valueText)
import GrimDawn.Db (GameDb (..), lookupRecord)
import GrimDawn.Gdc
  ( Character (..)
  , Item (..)
  , emptyItemName
  , itemWithName
  )
import GrimDawn.Item
  ( ItemAttrs (..)
  , characterBonuses
  , damageBonuses
  , itemAttrs
  , resistBonuses
  , skillBonuses
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
  ( AttackDps (..)
  , AttackKind (..)
  , BuffToggle (..)
  , Difficulty (..)
  , ScoreBase
  , StatSummary (..)
  , attackDps
  , defaultUpgradeTarget
  , defaultWeights
  , devotionSources
  , masterySources
  , mkScoreBase
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

setsView :: GameDb -> [OwnedItem] -> [SetView]
setsView db owned = map (toSetView db) (setReport db owned)

toSetView :: GameDb -> SetCompletion -> SetView
toSetView db sc =
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
    members = zipWith (toMemberView db setRec) [1 ..] (scMembers sc)

toMemberView :: GameDb -> Maybe Record -> Int -> SetMember -> SetMemberView
toMemberView db setRec tier m =
  SetMemberView
    { smvName = smName m
    , smvRecord = smRecord m
    , smvOwned = smOwned m
    , smvCount = smCount m
    , smvHoldings = [HoldingView loc n | (loc, n) <- smHoldings m]
    , smvGear = toGearView (smRecord m) Nothing Nothing (itemAttrs (itemWithName (smRecord m)) db)
    , smvSetTier = tier
    , smvSetBonus = maybe emptyBonusGroups (tierBonusGroups db tier) setRec
    }

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
  , cdvShopping :: ![ShoppingView] -- components/augments selected that aren't on the saved character
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
  , shopCount :: !Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON ShoppingView where toJSON = genericToJSON opts

-- | The character's effective stats (gear + devotions + mastery + always-on
-- buffs), folded for the difficulty noted in @ssvDifficulty@.
data StatSummaryView = StatSummaryView
  { ssvDifficulty :: !Text
  , ssvResists :: ![ResistView]
  , ssvAttributes :: ![NamedValueView] -- Physique/Cunning/Spirit absolute totals
  , ssvKeyTotals :: ![KeyTotalView] -- OA, DA, Armor, Health, Energy, ...
  , ssvDamage :: ![Text] -- total damage bonuses (e.g. "+120% Acid")
  }
  deriving (Show, Eq, Generic)

instance ToJSON StatSummaryView where toJSON = genericToJSON opts

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

-- | A what-if substitution of an equipped item's component and/or augment,
-- addressed by its index into the (non-empty) equipped-gear list. 'Nothing'
-- keeps the original; @Just ""@ clears the slot; @Just record@ sets it.
data GearOverride = GearOverride
  { goIndex :: !Int
  , goComponent :: !(Maybe Text)
  , goAugment :: !(Maybe Text)
  }
  deriving (Show, Eq)

detailView :: GameDb -> [GearOverride] -> Character -> CharacterDetailView
detailView db overrides c =
  CharacterDetailView
    { cdvName = charName c
    , cdvLevel = fromIntegral (charLevel c)
    , cdvClassName = className db c
    , cdvHardcore = charHardcore c
    , cdvSummary = toSummaryView difficulty (statSummary difficulty c sources)
    , cdvAttacks = map toAttackView (attackDps db sources c)
    , cdvGear = map gearViewOf items
    , cdvShopping = shoppingList db (equippedItems c) items
    }
  where
    -- The effective equipped set after applying any component/augment overrides;
    -- both the stat sources and the gear cards are built from it so they agree.
    items = applyOverrides overrides (equippedItems c)
    gearViewOf it = toGearView (itemBaseName it) (nonEmpty (itemRelicName it)) (nonEmpty (itemAugmentName it)) (itemAttrs it db)
    -- Effective stat sources, mirroring the `character`/`dps` CLI commands but
    -- folding in always-on (permanent) buffs and reporting at Ultimate, where
    -- the -50% resistance penalty makes the resist check meaningful.
    difficulty = Ultimate
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db items ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sources = statSources db items ++ extra

nonEmpty :: Text -> Maybe Text
nonEmpty t = if T.null t then Nothing else Just t

-- | Apply component/augment overrides to the equipped items by position.
applyOverrides :: [GearOverride] -> [Item] -> [Item]
applyOverrides overrides = zipWith apply [0 ..]
  where
    byIndex = HM.fromList [(goIndex o, o) | o <- overrides]
    apply i it = maybe it (`applyOverride` it) (HM.lookup i byIndex)
    applyOverride o it =
      it
        { itemRelicName = fromMaybe (itemRelicName it) (goComponent o)
        , itemAugmentName = fromMaybe (itemAugmentName it) (goAugment o)
        }

-- | The components/augments the effective build uses that the saved character
-- does not (counted), with a faction/shop hint for augments.
shoppingList :: GameDb -> [Item] -> [Item] -> [ShoppingView]
shoppingList db origs effs =
  [toShop kind rec (length (filter (== (kind, rec)) changes)) | (kind, rec) <- nub changes]
  where
    changes = concat (zipWith diff origs effs)
    diff o e =
      [("component", r) | let r = itemRelicName e, not (T.null r), r /= itemRelicName o]
        ++ [("augment", r) | let r = itemAugmentName e, not (T.null r), r /= itemAugmentName o]
    toShop kind rec n =
      ShoppingView
        { shopRecord = rec
        , shopName = fromMaybe (T.takeWhileEnd (/= '/') rec) (lookupRecord rec db >>= HM.lookup "description" >>= valueText)
        , shopKind = kind
        , shopSource = if kind == "augment" then augmentFaction db rec else Nothing
        , shopCount = n
        }

augmentFaction :: GameDb -> Text -> Maybe Text
augmentFaction db rec =
  (lookupRecord rec db >>= HM.lookup "factionSource" >>= valueText) >>= factionName

-- Faction-vendor names for the augment @factionSource@ enum. Each @UserN@ was
-- identified from the unambiguous faction-named augments it sells (e.g. User8
-- sells every "Kymon's …", User4 every "Outcast's …"); User0 is confirmed by
-- Nightshade Powder (Rovers) and User2 is the Black Legion by elimination
-- (Menhir's Blessing). Readable values (Forgotten Gods "Survivors") pass through.
factionName :: Text -> Maybe Text
factionName src = case src of
  "User0" -> Just "Rovers"
  "User2" -> Just "Black Legion"
  "User4" -> Just "The Outcast"
  "User5" -> Just "Order of Death's Vigil"
  "User7" -> Just "Devil's Crossing"
  "User8" -> Just "Kymon's Chosen"
  "User9" -> Just "Coven of Ugdenbog"
  "User10" -> Just "Barrowholm"
  "User11" -> Just "Malmouth Resistance"
  "User13" -> Just "Cult of Bysmiel"
  "User14" -> Just "Cult of Dreeg"
  "User15" -> Just "Cult of Solael"
  _
    | "User" `T.isPrefixOf` src -> Nothing -- unidentified faction enum
    | T.null src -> Nothing
    | otherwise -> Just src -- already a readable faction name

toSummaryView :: Difficulty -> StatSummary -> StatSummaryView
toSummaryView diff s =
  StatSummaryView
    { ssvDifficulty = case diff of Normal -> "Normal"; Elite -> "Elite"; Ultimate -> "Ultimate"
    , ssvResists = [ResistView n v cap over | (n, v, cap, over) <- ssResists s]
    , ssvAttributes = [NamedValueView l v | (l, v) <- ssAttributes s]
    , ssvKeyTotals = [KeyTotalView l flat pct | (l, flat, pct) <- ssKeyTotals s]
    , ssvDamage = ssDamage s
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
-- swaps the augment. Returns the record names in best-first order; records
-- absent from the result didn't pass the slot filter for that gear type.
rankEnhancements :: GameDb -> [GearOverride] -> Int -> Text -> Character -> [Text]
rankEnhancements db overrides slot kind c =
  case mFlag of
    Nothing -> []
    Just flag ->
      let cat = enhancementCatalog db
          pool = case kind of
            "component" -> cvComponents cat
            _ -> cvAugments cat
          compatible = [ev | ev <- pool, flag `elem` evSlots ev]
          scored = [(evRecord ev, fst5 (scoreItems sb (substitute (evRecord ev)))) | ev <- compatible]
       in map fst (sortOn (negate . snd) scored)
  where
    baseItems = applyOverrides overrides (equippedItems c)
    mTarget = case drop slot baseItems of
      (t : _) -> Just t
      [] -> Nothing
    mFlag = mTarget >>= \t -> enhancementSlotFlag (iaType (itemAttrs t db))
    -- match `detailView`'s effective stat sources (Ultimate, permanent buffs)
    difficulty = Ultimate
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
    fst5 (a, _, _, _, _) = a

-- localized class display name, falling back to the raw tag
className :: GameDb -> Character -> Text
className db c = HM.lookupDefault (charClassName c) (charClassName c) (gdbText db)
