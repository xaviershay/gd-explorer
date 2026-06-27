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
  , setsView
  , summaryView
  , detailView
  ) where

import Data.Aeson (Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Char (isUpper, toLower)
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)
import GHC.Generics (Generic)

import GrimDawn.Aggregate (OwnedItem)
import GrimDawn.Arz (Record, Value (..))
import GrimDawn.Db (GameDb (..), lookupRecord)
import GrimDawn.Gdc (Character (..), Item, emptyItemName, itemBaseName, itemWithName)
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
  , StatSummary (..)
  , attackDps
  , devotionSources
  , masterySources
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
    , smvGear = toGearView (smRecord m) (itemAttrs (itemWithName (smRecord m)) db)
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
  }
  deriving (Show, Eq, Generic)

instance ToJSON CharacterDetailView where toJSON = genericToJSON opts

-- | The character's effective stats (gear + devotions + mastery + always-on
-- buffs), folded for the difficulty noted in @ssvDifficulty@.
data StatSummaryView = StatSummaryView
  { ssvDifficulty :: !Text
  , ssvResists :: ![ResistView]
  , ssvAttributes :: ![NamedValueView] -- Physique/Cunning/Spirit absolute totals
  , ssvKeyTotals :: ![KeyTotalView] -- OA, DA, Armor, Health, Energy, ...
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

detailView :: GameDb -> Character -> CharacterDetailView
detailView db c =
  CharacterDetailView
    { cdvName = charName c
    , cdvLevel = fromIntegral (charLevel c)
    , cdvClassName = className db c
    , cdvHardcore = charHardcore c
    , cdvSummary = toSummaryView difficulty (statSummary difficulty c sources)
    , cdvAttacks = map toAttackView (attackDps db sources c)
    , cdvGear = map (\it -> toGearView (itemBaseName it) (itemAttrs it db)) (equippedItems c)
    }
  where
    -- Effective stat sources, mirroring the `character`/`dps` CLI commands but
    -- folding in always-on (permanent) buffs and reporting at Ultimate, where
    -- the -50% resistance penalty makes the resist check meaningful.
    difficulty = Ultimate
    base = charEquipped c
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db base ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sources = statSources db base ++ extra

toSummaryView :: Difficulty -> StatSummary -> StatSummaryView
toSummaryView diff s =
  StatSummaryView
    { ssvDifficulty = case diff of Normal -> "Normal"; Elite -> "Elite"; Ultimate -> "Ultimate"
    , ssvResists = [ResistView n v cap over | (n, v, cap, over) <- ssResists s]
    , ssvAttributes = [NamedValueView l v | (l, v) <- ssAttributes s]
    , ssvKeyTotals = [KeyTotalView l flat pct | (l, flat, pct) <- ssKeyTotals s]
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

toGearView :: Text -> ItemAttrs -> GearView
toGearView record a =
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
    }

equippedItems :: Character -> [Item]
equippedItems = filter (not . emptyItemName) . charEquipped

-- localized class display name, falling back to the raw tag
className :: GameDb -> Character -> Text
className db c = HM.lookupDefault (charClassName c) (charClassName c) (gdbText db)
