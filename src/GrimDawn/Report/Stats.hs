-- | Aggregated character stat totals from equipped gear (and, via the supplied
-- item list, any overlaid candidate gear): resistances with their cap and the
-- difficulty penalty, offensive/defensive ability, key defensive totals, weapon
-- damage, and total damage bonuses.
module GrimDawn.Report.Stats
  ( Difficulty (..)
  , parseDifficulty
  , difficultyPenalty
  , SourceCategory (..)
  , Source (..)
  , mkSource
  , plainSources
  , SourceAmount (..)
  , TypeDetail (..)
  , RetaliationTypeDetail (..)
  , RetaliationDetail (..)
  , RateFactorDetail (..)
  , TriggerDetail (..)
  , SourceImpact (..)
  , AttackBreakdown (..)
  , attackDpsBreakdown
  , retaliationPseudoSource
  , statSources
  , devotionSources
  , masterySources
  , BuffToggle (..)
  , noBuffs
  , parseBuffs
  , skillSources
  , overlay
  , overlayAt
  , inheritGear
  , renderStats
  , renderStatsDiff
  , StatSummary (..)
  , statSummary
    -- * Upgrade search
  , Weights (..)
  , defaultWeights
  , setWeight
  , UpgradeRow (..)
  , findUpgrades
  , renderUpgradeRow
  , ScoreBase
  , mkScoreBase
  , scoreItems
  , defaultUpgradeTarget
    -- * Attack DPS estimate
  , assumedBaseAttackSpeed
  , AttackKind (..)
  , AttackDps (..)
  , attackDps
  , parseProcController
  , renderDps
    -- * Resistance reduction (applied to enemies)
  , resistReductionLines
  ) where

import Data.Char (isDigit, isLower, toLower)
import qualified Data.HashMap.Strict as HM
import Data.List (find, intercalate, nub, nubBy, sortOn, (\\))
import Data.Maybe (fromMaybe, listToMaybe)
import Text.Read (readMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Arz (Record, Value (..), lookupField, valueText)
import GrimDawn.Db (GameDb, lookupRecord)
import GrimDawn.Gdc (Character (..), Item (..), Skill (..), emptyItemName, itemWithName)
import GrimDawn.Item
  ( damageElems
  , damageBonuses
  , damageTable
  , DamageRow (..)
  , dotElems
  , effectDisplay
  , itemAttrs
  , ItemAttrs (..)
  , relatedRecords
  , resistFieldMap
  , resolveSetTier
  , setRecordName
  , skillDisplayName
  , sumField
  , sumRange
  )
import GrimDawn.Report.Color (colorByType)

--------------------------------------------------------------------------------
-- Source attribution
--------------------------------------------------------------------------------

-- | The kind of thing that granted a stat-contributing record, for the DPS
-- attribution breakdown ('GrimDawn.Report.Stats.attackDpsBreakdown').
data SourceCategory
  = SrcGear | SrcComponent | SrcAugment | SrcSetBonus
  | SrcDevotion | SrcMastery | SrcSkill | SrcOther
  deriving (Show, Eq)

-- | A stat-contributing record's owner: a display label and category for
-- attribution, plus the original record-path key so existing dedup/equality
-- logic over @[(Text, Record)]@ keeps working unchanged — 'Eq'/'Ord' defer to
-- the key alone, ignoring label/category.
data Source = Source
  { srcKey :: !Text
  , srcLabel :: !Text
  , srcCategory :: !SourceCategory
  }
  deriving (Show)

instance Eq Source where
  a == b = srcKey a == srcKey b

instance Ord Source where
  compare a b = compare (srcKey a) (srcKey b)

mkSource :: Text -> SourceCategory -> Text -> Source
mkSource key cat label = Source key label cat

-- | Strip a 'Source'-tagged sources list back down to the plain
-- @[(Text, Record)]@ shape 'GrimDawn.Item''s aggregation helpers
-- ('GrimDawn.Item.sumField', 'GrimDawn.Item.sumRange', ...) and the plain
-- stat-summary functions below expect.
plainSources :: [(Source, Record)] -> [(Text, Record)]
plainSources = map (\(s, r) -> (srcKey s, r))

-- | One source's contribution to a flat amount or a percentage figure.
data SourceAmount = SourceAmount
  { saSource :: !Source
  , saValue :: !Double
  }
  deriving (Show, Eq)

-- | One damage type's full per-hit breakdown for a single attack/proc row:
-- the flat contributors (summing to 'tdFlatSubtotal'), and either the
-- immediate-damage percent contributors ('tdPercentSources') or — for a
-- damage-over-time row (label ends " (dot)") — the duration and damage
-- percent contributors kept separate, since a DoT's total is
-- @flatSubtotal x (1 + durationPct/100) x (1 + damagePct/100)@: two
-- multiplicative pools, not one. Immediate rows leave the duration/damage-pct
-- fields empty; DoT rows leave 'tdPercentSources'/'tdTotalPercent' empty.
data TypeDetail = TypeDetail
  { tdLabel :: !Text
  , tdTotal :: !Double
  , tdFlatSources :: ![SourceAmount]
  , tdFlatSubtotal :: !Double
  , tdPercentSources :: ![SourceAmount]
  , tdTotalPercent :: !Double
  , tdDurationSources :: ![SourceAmount]
  , tdTotalDurationPercent :: !Double
  , tdDamagePctSources :: ![SourceAmount]
  , tdTotalDamagePercent :: !Double
  }
  deriving (Show, Eq)

-- | The synthetic "source" for the retaliation-added-to-attack flat line in a
-- 'TypeDetail' — it's a computed aggregate of several real sources (see
-- 'retaliationByStem'), not one source, so it isn't further splittable within
-- the flat table.
retaliationPseudoSource :: Source
retaliationPseudoSource = Source "__retaliation__" "Retaliation added to attack" SrcOther

-- | Retaliation's own flat -> % -> % chain for one damage type: its own flat
-- retaliation stat (x its own % modifiers), and the resulting contribution to
-- an attack once the shared "% of retaliation damage added to attack" is
-- applied. See 'retaliationByStem'.
data RetaliationTypeDetail = RetaliationTypeDetail
  { rtdLabel :: !Text
  , rtdFlatSources :: ![SourceAmount]
  , rtdFlatSubtotal :: !Double
  , rtdPercentSources :: ![SourceAmount]
  , rtdTotalPercent :: !Double
  , rtdRetaliationDamage :: !Double -- flatSubtotal x (1 + totalPercent/100)
  , rtdAddedToAttack :: !Double -- retaliationDamage x (shared add-to-attack %)/100
  }
  deriving (Show, Eq)

-- | Retaliation damage added to an attack: the shared "% of retaliation
-- damage added to attack" (one scalar, applied to every damage type), and
-- each affected type's own flat/percent retaliation chain.
data RetaliationDetail = RetaliationDetail
  { rdAddToAttackSources :: ![SourceAmount]
  , rdTotalAddToAttackPct :: !Double
  , rdByType :: ![RetaliationTypeDetail]
  }
  deriving (Show, Eq)

-- | A rate-affecting factor (attack speed, cooldown reduction, weapon
-- damage %) and the sources contributing to it.
data RateFactorDetail = RateFactorDetail
  { rfdLabel :: !Text
  , rfdBase :: !Double
  , rfdSources :: ![SourceAmount]
  , rfdEffective :: !Double
  , rfdFormula :: !Text
  }
  deriving (Show, Eq)

-- | A proc's trigger: chance, base cooldown, and the single record that
-- grants it (only one record ever grants a given proc, unlike the
-- contributor lists above).
data TriggerDetail = TriggerDetail
  { trgChancePct :: !Double
  , trgCooldown :: !Double
  , trgGrantedBy :: !Text
  }
  deriving (Show, Eq)

-- | One source's estimated impact on a row's DPS: the row's current DPS
-- minus its DPS with that source's records excluded, holding everything
-- else fixed. Independent counterfactuals — not required to sum to the
-- row's total DPS (see the design doc's "Why flat and % stay separate").
data SourceImpact = SourceImpact
  { siSource :: !Source
  , siDpsImpact :: !Double
  }
  deriving (Show, Eq)

-- | The full source-attributed breakdown for one attack/proc row.
data AttackBreakdown = AttackBreakdown
  { abName :: !Text
  , abRank :: !(Maybe Int)
  , abKind :: !AttackKind
  , abPerHit :: !Double
  , abDps :: !Double
  , abRate :: !Text
  , abSourcesByImpact :: ![SourceImpact]
  , abTypes :: ![TypeDetail]
  , abRetaliation :: !(Maybe RetaliationDetail)
  , abRateFactors :: ![RateFactorDetail]
  , abTrigger :: !(Maybe TriggerDetail)
  }
  deriving (Show, Eq)

-- | One row's full detail: the existing summary ('AttackDps'), plus every
-- piece 'attackDpsBreakdown' needs, plus the distinct sources that touched
-- it (for the DPS-impact ranking). Computed once per row inside
-- 'attackDpsRows' so 'attackDps' (which just projects 'rdSummary') and
-- 'attackDpsBreakdown' can never disagree.
data RowDetail = RowDetail
  { rdSummary :: !AttackDps
  , rdTypes :: ![TypeDetail]
  , rdRetaliation :: !(Maybe RetaliationDetail)
  , rdRateFactors :: ![RateFactorDetail]
  , rdTrigger :: !(Maybe TriggerDetail)
  , rdSourcesTouched :: ![Source]
  }

--------------------------------------------------------------------------------
-- Difficulty
--------------------------------------------------------------------------------

-- | Difficulty determines the flat resistance penalty applied to the character.
data Difficulty = Normal | Elite | Ultimate
  deriving (Show, Eq)

-- | Flat resistance penalty per type and difficulty.
-- Elite:    -25% on fire/cold/lightning/poison/pierce only.
-- Ultimate: -50% on those 5, -25% on bleeding/vitality/aether/chaos.
-- physical has no penalty at any difficulty.
difficultyPenalty :: Difficulty -> Text -> Double
difficultyPenalty Normal   _  = 0
difficultyPenalty Elite    ty = if ty `elem` bigFive then 25 else 0
difficultyPenalty Ultimate ty
  | ty `elem` bigFive  = 50
  | ty `elem` medFour  = 25
  | otherwise          = 0

bigFive :: [Text]
bigFive = ["fire", "cold", "lightning", "poison", "pierce"]

medFour :: [Text]
medFour = ["bleed", "vitality", "aether", "chaos"]

parseDifficulty :: String -> Maybe Difficulty
parseDifficulty s = case map toLower s of
  "normal" -> Just Normal
  "veteran" -> Just Normal
  "elite" -> Just Elite
  "ultimate" -> Just Ultimate
  _ -> Nothing

--------------------------------------------------------------------------------
-- Stat sources
--------------------------------------------------------------------------------

-- | Every stat-bearing record contributed by a character's equipped gear,
-- tagged with its owning 'Source' for the DPS attribution breakdown: each
-- item's base+affix records under one "Gear" source (the item's display
-- name), its relic (+relic-bonus) under a separate "Component" source, its
-- augment under a separate "Augment" source, plus each active set-completion
-- tier under a "Set Bonus" source. (Devotion and skill buffs are layered on
-- by callers later.)
statSources :: GameDb -> [Item] -> [(Source, Record)]
statSources db items =
  concatMap itemSources equipped ++ setTiers
  where
    equipped = filter (not . emptyItemName) items
    itemSources it =
      [ (mkSource n SrcGear (labelOf it), r)
      | n <-
          filter
            (T.isPrefixOf "records/")
            [itemBaseName it, itemPrefixName it, itemSuffixName it, itemModifierName it, itemTransmuteName it]
      , Just r <- [lookupRecord n db]
      ]
        ++ [ (mkSource n SrcComponent (labelOf (itemWithName (itemRelicName it))), r)
           | n <- [itemRelicName it, itemRelicBonus it]
           , not (T.null n)
           , Just r <- [lookupRecord n db]
           ]
        ++ [ (mkSource n SrcAugment (labelOf (itemWithName (itemAugmentName it))), r)
           | n <- [itemAugmentName it]
           , not (T.null n)
           , Just r <- [lookupRecord n db]
           ]
    labelOf it = iaDisplayName (itemAttrs it db)
    setRecs = [s | it <- equipped, Just s <- [setRecordName it db]]
    setTiers =
      [ (mkSource rec SrcSetBonus (setLabel rec r cnt), resolveSetTier cnt r)
      | rec <- nub setRecs
      , Just r <- [lookupRecord rec db]
      , let cnt = length (filter (== rec) setRecs)
      ]
    setLabel rec r cnt =
      fromMaybe (T.takeWhileEnd (/= '/') rec) (lookupField "setName" r >>= valueText)
        <> " ("
        <> T.pack (show cnt)
        <> "pc)"

-- | Passive stat records granted by a character's chosen devotions: each taken
-- constellation star (excluding the @*_skill@ celestial-power procs, which are
-- granted skills rather than always-on passives).
--
-- The save lists *every* star of any touched constellation, including ones the
-- character has not allocated a point to (@skLevel == 0@); those must be skipped
-- or their passives (resistances, etc.) inflate the totals.
devotionSources :: GameDb -> Character -> [(Source, Record)]
devotionSources db c =
  [ (mkSource (skName s) SrcDevotion (skillDisplayName db (skName s)), r)
  | s <- charSkills c
  , skLevel s > 0
  , "/devotion/tier" `T.isInfixOf` skName s
  , not ("_skill" `T.isSuffixOf` T.dropEnd 4 (skName s))
  , Just r <- [lookupRecord (skName s) db]
  ]

-- | Always-on stat records from a character's mastery bars, resolved at the
-- invested mastery rank (they grant attributes, health, and energy by rank).
masterySources :: GameDb -> Character -> [(Source, Record)]
masterySources db c =
  [ (mkSource (skName s) SrcMastery (skillDisplayName db (skName s)), resolveSetTier (fromIntegral (skLevel s)) r)
  | s <- charSkills c
  , "_classtraining_" `T.isInfixOf` skName s
  , skLevel s > 0
  , Just r <- [lookupRecord (skName s) db]
  ]

--------------------------------------------------------------------------------
-- Skill buffs
--------------------------------------------------------------------------------

-- | How a skill buff is classified, mirroring Grim Tools' togglable categories.
data BuffCategory = Permanent | Temporary | Proc
  deriving (Eq, Show)

-- | Which categories of skill buff to fold into the stats.
data BuffToggle = BuffToggle
  { tgPermanent :: !Bool
  , tgTemporary :: !Bool
  , tgProc :: !Bool
  }
  deriving (Eq, Show)

noBuffs :: BuffToggle
noBuffs = BuffToggle False False False

-- | Parse a comma-separated category list, e.g. @permanent,temporary@, @all@, @none@.
parseBuffs :: String -> Either String BuffToggle
parseBuffs s = go noBuffs (map (T.toLower . T.strip) (T.splitOn "," (T.pack s)))
  where
    go acc [] = Right acc
    go acc (x : xs) = case x of
      "permanent" -> go acc {tgPermanent = True} xs
      "temporary" -> go acc {tgTemporary = True} xs
      "proc" -> go acc {tgProc = True} xs
      "all" -> go (BuffToggle True True True) xs
      "none" -> go acc xs
      "" -> go acc xs
      other -> Left ("unknown buff category: " <> T.unpack other)

allowed :: BuffToggle -> BuffCategory -> Bool
allowed t Permanent = tgPermanent t
allowed t Temporary = tgTemporary t
allowed t Proc = tgProc t

-- classify a skill record by its template (Nothing = not a stat buff we fold in).
skillCategory :: Record -> Maybe BuffCategory
skillCategory rec =
  case fmap T.toLower (lookupField "templateName" rec >>= valueText) of
    Just t
      | "passive" `T.isInfixOf` t || "toggled" `T.isInfixOf` t -> Just Permanent
      | "duration" `T.isInfixOf` t -> Just Temporary
      | "proc" `T.isInfixOf` t -> Just Proc
    _ -> Nothing

-- the record carrying a skill's stats: its buff record if it has one, else itself.
buffStatRecord :: GameDb -> Record -> Record
buffStatRecord db rec =
  case lookupField "buffSkillName" rec >>= valueText >>= (`lookupRecord` db) of
    Just b -> b
    Nothing -> rec

-- scalar value of a field on a single record
recNum :: Record -> Text -> Maybe Double
recNum r f = case lookupField f r of
  Just (VInt i) -> Just (fromIntegral i)
  Just (VFloat x) -> Just (realToFrac x)
  _ -> Nothing

-- | The @+to skills@ bonuses available from a set of stat sources (gear,
-- devotions): @(+all skills, mastery-record -> +levels, skill-record -> +levels)@.
collectSkillLevels :: [(Text, Record)] -> (Double, HM.HashMap Text Double, HM.HashMap Text Double)
collectSkillLevels sources = (allLvl, byMastery, bySkill)
  where
    allLvl = sumField sources "augmentAllLevel"
    byMastery =
      HM.fromListWith (+)
        [ (nm, lvl)
        | (_, r) <- sources
        , i <- idxs
        , Just nm <- [lookupField ("augmentMasteryName" <> i) r >>= valueText]
        , Just lvl <- [recNum r ("augmentMasteryLevel" <> i)]
        ]
    bySkill =
      HM.fromListWith (+)
        [ (nm, lvl)
        | (_, r) <- sources
        , i <- idxs
        , Just nm <- [lookupField ("augmentSkillName" <> i) r >>= valueText]
        , Just lvl <- [recNum r ("augmentSkillLevel" <> i)]
        ]
    idxs = map (T.pack . show) [1 .. 6 :: Int]

-- | A skill's effective rank: invested rank plus the @+all/+mastery/+specific@
-- bonuses collected from a context (see 'collectSkillLevels').
rankWith :: (Double, HM.HashMap Text Double, HM.HashMap Text Double) -> Skill -> Int
rankWith (allLvl, byMastery, bySkill) s =
  max 1 . round $
    fromIntegral (skLevel s)
      + allLvl
      + HM.lookupDefault 0 (masteryRecordOf (skName s)) byMastery
      + HM.lookupDefault 0 (skName s) bySkill

-- the mastery training record a class skill belongs to, e.g.
-- ".../playerclass09/foo.dbr" -> ".../playerclass09/_classtraining_class09.dbr".
masteryRecordOf :: Text -> Text
masteryRecordOf p =
  case listToMaybe (filter ("playerclass" `T.isPrefixOf`) (T.splitOn "/" p)) of
    Just seg ->
      let n = T.drop (T.length "playerclass") seg
       in "records/skills/" <> seg <> "/_classtraining_class" <> n <> ".dbr"
    Nothing -> ""

-- | Stat records granted by a character's invested class skills, restricted to
-- the enabled buff categories and resolved at the *effective* rank — invested
-- rank plus the @+all skills@, @+mastery@ and @+specific skill@ bonuses found in
-- @ctx@ (gear + devotions). Skill modifier nodes (e.g. the resistances a node
-- adds to an aura) are folded in too, inheriting their parent skill's category;
-- attack skills are not folded in (their bonuses are conditional on the ability).
skillSources :: BuffToggle -> [(Source, Record)] -> GameDb -> Character -> [(Source, Record)]
skillSources tog ctx db c =
  [ (mkSource (skName s) SrcSkill (skillDisplayName db (skName s)), resolveSetTier (effRank s) (buffStatRecord db skRec))
  | s <- charSkills c
  , skLevel s > 0
  , "records/skills/playerclass" `T.isPrefixOf` skName s
  , not ("_classtraining_" `T.isInfixOf` skName s)
  , Just skRec <- [lookupRecord (skName s) db]
  , Just cat <- [effectiveCategory skRec (skName s)]
  , allowed tog cat
  ]
  where
    effRank = rankWith (collectSkillLevels (plainSources ctx))

    -- base skill name -> intrinsic category, from this character's invested
    -- skills that have one (used so modifier nodes can inherit it).
    catByBase =
      HM.fromList
        [ (skillBase (skName s), cat)
        | s <- charSkills c
        , Just r <- [lookupRecord (skName s) db]
        , Just cat <- [skillCategory r]
        ]
    -- a node's category: its own, or (for a modifier/transmuter) its parent's.
    effectiveCategory rec path =
      case skillCategory rec of
        Just cat -> Just cat
        Nothing
          | isModifierLike rec -> HM.lookup (skillBase path) catByBase
          | otherwise -> Nothing
    isModifierLike r =
      case fmap T.toLower (lookupField "templateName" r >>= valueText) of
        Just t -> "modifier" `T.isInfixOf` t || "transmuter" `T.isInfixOf` t
        _ -> False

-- skill record path -> base name, stripping the trailing @N@/@Nx@ variant suffix,
-- e.g. ".../presenceofvirtue2.dbr" and ".../presenceofvirtue1b.dbr" -> "presenceofvirtue".
skillBase :: Text -> Text
skillBase path = T.pack (reverse (dropWhile isDigit (dropVariantLetter (reverse leaf))))
  where
    leaf = T.unpack (T.dropEnd 4 (lastSeg path))
    lastSeg p = case T.splitOn "/" p of [] -> p; ws -> last ws
    dropVariantLetter (x : y : rest) | isLower x && isDigit y = y : rest
    dropVariantLetter xs = xs

--------------------------------------------------------------------------------
-- Overlay
--------------------------------------------------------------------------------

-- | Overlay candidate item(s) onto a base equipped list: each candidate replaces
-- the equipped item occupying the same slot (matched by item type), keeping the
-- rest of the base character. A candidate with no matching slot is added.
overlay :: GameDb -> [Item] -> [Item] -> [Item]
overlay db = foldl swap
  where
    swap equipped cand =
      case break (\e -> slotType e == slotType cand) equipped of
        (before, old : after) -> before ++ inheritGear old cand : after
        (before, []) -> before ++ [cand]
    slotType it = iaType (itemAttrs it db)

-- | Like 'overlay' for a single candidate, but replace the @n@-th (0-based)
-- equipped item of the candidate's slot type rather than the first — so a specific
-- ring slot can be targeted (ring1 = 0, ring2 = 1). If there are fewer than @n+1@
-- equipped items of that type (e.g. an empty ring slot) the candidate fills the
-- slot by being appended.
overlayAt :: GameDb -> Int -> [Item] -> Item -> [Item]
overlayAt db n equipped cand = go n equipped
  where
    ty = iaType (itemAttrs cand db)
    sameSlot e = iaType (itemAttrs e db) == ty
    go _ [] = [cand]
    go k (e : es)
      | sameSlot e = if k <= 0 then inheritGear e cand : es else e : go (k - 1) es
      | otherwise = e : go k es

-- | A candidate keeps its own component/augment where it has one, otherwise it
-- inherits the replaced item's — so swapping a bare drop in keeps your sockets for
-- a fair comparison (you'd move them over). Component fields (name, bonus, seed,
-- completion) and augment fields (name, seed) move as a group.
inheritGear :: Item -> Item -> Item
inheritGear old cand =
  let comp = if T.null (itemRelicName cand) then old else cand
      aug = if T.null (itemAugmentName cand) then old else cand
   in cand
        { itemRelicName = itemRelicName comp
        , itemRelicBonus = itemRelicBonus comp
        , itemRelicSeed = itemRelicSeed comp
        , itemRelicCompletionLevel = itemRelicCompletionLevel comp
        , itemAugmentName = itemAugmentName aug
        , itemAugmentSeed = itemAugmentSeed aug
        }

--------------------------------------------------------------------------------
-- Resistances
--------------------------------------------------------------------------------

-- the default maximum for any single resistance, before +max modifiers.
baseResistCap :: Double
baseResistCap = 80

-- resist key -> the field stem used by its +max-resist field and component token.
resistStem :: Text -> Text
resistStem "vitality" = "Life"
resistStem "bleed" = "Bleeding"
resistStem ty = capitalizeT ty

resistToken :: Text -> Text
resistToken "vitality" = "life"
resistToken "bleed" = "bleeding"
resistToken ty = ty

-- one resistance row: (display name, effective %, cap, overcap)
resistRows :: Difficulty -> [(Text, Record)] -> [(Text, Double, Double, Double)]
resistRows diff sources =
  [ (name, effective, cap, overcap)
  | (ty, fields) <- resistFieldMap
  , let gear = sum (map (sumField sources) fields)
        cap = baseResistCap + sumField sources ("defensive" <> resistStem ty <> "MaxResist") + sumField sources "defensiveAllMaxResist"
        afterPenalty = gear - difficultyPenalty diff ty
        effective = min afterPenalty cap
        overcap = max 0 (afterPenalty - cap)
        name = effectDisplay ["defensive"] (resistToken ty)
  ]

-- | The three primary attributes as @(label, bio base, flat field, % field)@.
attrFieldsOf :: Character -> [(Text, Double, Text, Text)]
attrFieldsOf c =
  [ ("Physique", charPhysique c, "characterStrength", "characterStrengthModifier")
  , ("Cunning", charCunning c, "characterDexterity", "characterDexterityModifier")
  , ("Spirit", charSpirit c, "characterIntelligence", "characterIntelligenceModifier")
  ]

-- | The structured stats summary behind 'renderStats': effective resistances
-- (name, %, cap, overcap), absolute attributes, and the key offensive/defensive
-- totals (label, flat, %). @sources@ must already include gear + buffs.
data StatSummary = StatSummary
  { ssResists :: ![(Text, Double, Double, Double)]
  , ssAttributes :: ![(Text, Double)]
  , ssKeyTotals :: ![(Text, Double, Double)]
  , ssHealthTotal :: !Double -- computed max Health (bio base + attrs + gear/buffs)
  , ssEnergyTotal :: !Double -- computed max Energy
  , ssOaTotal :: !Double -- computed OA total using level/attr/gear formula
  , ssDaTotal :: !Double -- computed DA total using level/attr/gear formula
  , ssDamage :: ![Text] -- total damage bonuses (e.g. "+120% Acid"), gear + buffs
  , ssDamageTable :: ![DamageRow] -- per-damage-type table: instant + DoT flat & %
  , ssCcResists :: ![(Text, Double, Double, Double)] -- (label, effective %, cap, overcap)
  }
  deriving (Show, Eq)

-- Crowd-control resistances: additive, capped at 80% (like elemental resists).
ccResistFields :: [(Text, Text)]
ccResistFields =
  [ ("Slow Resistance", "defensiveTotalSpeedResistance")
  , ("Stun Resistance", "defensiveStun")
  , ("Freeze Resistance", "defensiveFreeze")
  , ("Trap Resistance", "defensiveTrap")
  ]

ccResistCap :: Double
ccResistCap = 80

-- Armor absorption starts at a 70% base; @defensiveAbsorptionModifier@ (the
-- "% Increased Armor Absorption" from gear/skills) raises it *multiplicatively*,
-- e.g. +36% -> 70 * 1.36 = 95.2%. Hard cap 100%.
armorAbsorptionBase :: Double
armorAbsorptionBase = 70

statSummary :: Difficulty -> Character -> [(Text, Record)] -> StatSummary
statSummary diff c sources =
  StatSummary
    { ssResists = resistRows diff sources
    , ssAttributes = attrTotals
    , ssKeyTotals =
        [ row | row@(label, _, _) <- keyTotalsOf sources
        , label `notElem` ["Physique", "Cunning", "Spirit", "Offensive Ability", "Defensive Ability"]
        ]
    , ssHealthTotal = healthTotal
    , ssEnergyTotal = energyTotal
    , ssOaTotal = oaTotal
    , ssDaTotal = daTotal
    , ssDamage = damageBonuses sources
    , ssDamageTable = damageTable sources
    , ssCcResists = armorAbsorption : blockChance ++ ccRows
    }
  where
    armorAbsorption =
      let raw = armorAbsorptionBase * (1 + sumField sources "defensiveAbsorptionModifier" / 100)
       in ("Armor Absorption", min raw 100, 100, max 0 (raw - 100))
    -- Shield block chance (only with a shield equipped); the flat chance scaled
    -- by any % block-chance modifier, capped at 100%.
    blockChance =
      let raw =
            sumField sources "defensiveBlockChance"
              * (1 + sumField sources "defensiveBlockChanceModifier" / 100)
       in [("Block Chance", min raw 100, 100, max 0 (raw - 100)) | raw /= 0]
    ccRows =
      [ (label, min raw ccResistCap, ccResistCap, max 0 (raw - ccResistCap))
      | (label, field) <- ccResistFields
      , let raw = sumField sources field
      , raw /= 0
      ]
    attrTotals =
      [ (label, (baseV + sumField sources flatField) * (1 + sumField sources pctField / 100))
      | (label, baseV, flatField, pctField) <- attrFieldsOf c
      ]
    totalAttr label = maybe 0 snd (find ((== label) . fst) attrTotals)
    -- Health/Energy are derived, not stored as live totals: the bio block keeps
    -- only the attribute-derived base (charHealth/charEnergy). Add the health/
    -- energy from attributes gained beyond the bio base (mastery/gear/devotion),
    -- plus flat +Health/+Energy, then scale by the % modifier. Per-attribute
    -- rates are GD's published constants (see [[gd-stats-and-factions]] notes).
    bonusHealth =
      (totalAttr "Physique" - charPhysique c) * 2.5
        + (totalAttr "Cunning" - charCunning c) * 1.0
        + (totalAttr "Spirit" - charSpirit c) * 1.0
    bonusEnergy = (totalAttr "Spirit" - charSpirit c) * 2.0
    healthTotal =
      (charHealth c + bonusHealth + sumField sources "characterLife")
        * (1 + sumField sources "characterLifeModifier" / 100)
    energyTotal =
      (charEnergy c + bonusEnergy + sumField sources "characterMana")
        * (1 + sumField sources "characterManaModifier" / 100)
    lvl = fromIntegral (charLevel c) :: Double
    -- OA = (115 + 12*Level + 0.4*Cunning + flat bonuses) * (1 + %OA/100)
    -- DA = (115 + 12*Level + 0.4*Spirit  + flat bonuses) * (1 + %DA/100)
    oaTotal =
      (115 + 12 * lvl + 0.4 * totalAttr "Cunning" + sumField sources "characterOffensiveAbility")
        * (1 + sumField sources "characterOffensiveAbilityModifier" / 100)
    daTotal =
      (115 + 12 * lvl + 0.4 * totalAttr "Spirit" + sumField sources "characterDefensiveAbility")
        * (1 + sumField sources "characterDefensiveAbilityModifier" / 100)

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- | Render the stats summary for a character whose effective equipped list is
-- @items@ (already overlaid, if applicable). @extra@ holds non-gear stat sources
-- such as mastery, devotion and skill buffs. Attributes are shown as absolute
-- totals (the bio base plus those sources); OA/DA and the defensive totals are
-- shown as the contribution from those sources (the innate per-level base is not
-- in the extracted database).
renderStats :: Bool -> Difficulty -> Character -> [(Text, Record)] -> GameDb -> [Item] -> Text
renderStats useColor diff c extra db items =
  T.unlines $
    ("Stats  [" <> tshow diff <> penaltyNote <> "]")
      : ""
      : "Resistances:"
      : map resistLine (resistRows diff sources)
      ++ ["", "Attributes:"]
      ++ map ("  " <>) attrLines
      ++ ["", "Defenses & Offense (from gear/mastery/buffs):"]
      ++ map ("  " <>) keyTotals
      ++ blank weaponLines
      ++ weaponLines
      ++ blank dmgLines
      ++ dmgLines
  where
    sources = plainSources (statSources db items) ++ extra
    equipped = filter (not . emptyItemName) items
    blank xs = if null xs then [] else [""]
    penaltyNote = case diff of
      Normal   -> ""
      Elite    -> ": -25% elem/pierce"
      Ultimate -> ": -50% elem/pierce, -25% bleed/vit/aether/chaos"

    resistLine (name, eff, cap, over) =
      "  "
        <> pad 16 name
        <> rpad 6 (showN eff <> "%")
        <> "  (cap "
        <> showN cap
        <> (if over > 0 then ", +" <> showN over <> " over" else "")
        <> ")"
        <> (if eff < 0 then "   LOW" else "")

    -- absolute attributes: (bio base + flat from sources) scaled by % modifier
    attrLines =
      [ pad 12 label <> rpad 6 (T.pack (show (round total :: Integer)))
      | (label, baseV, flatField, pctField) <- attrFields
      , let flat = sumField sources flatField
            pct = sumField sources pctField
            total = (baseV + flat) * (1 + pct / 100)
      ]
    attrFields = attrFieldsOf c

    -- key flat (+ %) contributions, excluding the attributes shown above
    keyTotals =
      [ pad 20 label <> sign flat <> (if pct /= 0 then "  (" <> sign pct <> "%)" else "")
      | (label, flat, pct) <- keyTotalsOf sources
      , label `notElem` ["Physique", "Cunning", "Spirit"]
      ]

    -- equipped weapons and their base damage range by type
    weaponLines
      | null ws = []
      | otherwise = "Weapon damage:" : map ("  " <>) ws
      where
        ws =
          [ iaDisplayName (itemAttrs it db) <> ":  " <> T.intercalate ", " parts
          | it <- equipped
          , isWeapon it
          , let related = relatedRecords it db
                parts =
                  [ "+" <> rangeStr lo hi <> " " <> effectDisplay ["offensive"] tok
                  | (stem, tok) <- damageElems
                  , let (lo, hi) = sumRange related ["offensive", "offensiveBase", "offensiveBonus"] stem
                  , hi > 0
                  ]
          , not (null parts)
          ]

    isWeapon it =
      case lookupRecord (itemBaseName it) db >>= lookupField "Class" >>= valueText of
        Just cls -> any (`T.isPrefixOf` cls) ["WeaponMelee", "WeaponHunting"]
        _ -> False

    -- total damage bonuses across all gear (flat ranges then % modifiers)
    dmgLines =
      case damageBonuses sources of
        [] -> []
        ds -> ["Damage from gear:", "  " <> T.intercalate ", " (map (colorByType useColor) ds)]

-- | Render only what changed between the base equipped gear and an overlaid
-- build: effective resistances and the key flat totals, as @base -> new (delta)@.
renderStatsDiff :: Bool -> Difficulty -> [(Text, Record)] -> GameDb -> [Item] -> [Item] -> Text
renderStatsDiff _useColor diff extra db base over =
  T.unlines $
    ("Overlay vs equipped  [" <> tshow diff <> "]")
      : ""
      : "Resistances:"
      : (if null resistDiff then ["  (no change)"] else resistDiff)
      ++ ["", "Defenses & Offense:"]
      ++ (if null defenseDiff then ["  (no change)"] else defenseDiff)
  where
    srcB = plainSources (statSources db base) ++ extra
    srcO = plainSources (statSources db over) ++ extra
    rB = resistRows diff srcB
    rO = resistRows diff srcO
    resistDiff =
      [ "  " <> pad 16 name <> rpad 5 (showN eb <> "%") <> " -> " <> rpad 5 (showN eo <> "%") <> "  (" <> sign (eo - eb) <> ")"
      | ((name, eb, _, _), (_, eo, _, _)) <- zip rB rO
      , eb /= eo
      ]
    kB = keyTotalsOf srcB
    kO = keyTotalsOf srcO
    labels = nub (map fst3 kB ++ map fst3 kO)
    keyDiff =
      [ "  " <> pad 20 label <> rpad 7 (sign fb) <> " -> " <> rpad 7 (sign fo) <> "  (" <> sign (fo - fb) <> ")"
      | label <- labels
      , let fb = flatOf label kB
            fo = flatOf label kO
      , fb /= fo
      ]
    -- a single "offensive value" proxy (flat damage + all % modifiers)
    dmgB = damageScore srcB
    dmgO = damageScore srcO
    dmgDiff =
      [ "  " <> pad 20 "Damage" <> rpad 7 (sign dmgB) <> " -> " <> rpad 7 (sign dmgO) <> "  (" <> sign (dmgO - dmgB) <> ")"
      | dmgB /= dmgO
      ]
    defenseDiff = keyDiff ++ dmgDiff
    flatOf l ks = case [f | (lab, f, _) <- ks, lab == l] of (x : _) -> x; [] -> 0
    fst3 (a, _, _) = a

-- | A single offensive-value proxy for an overlay diff: total flat damage plus
-- all percentage damage modifiers (immediate + damage-over-time). Crude (a build
-- weights damage types very differently) but directional for gear comparison.
damageScore :: [(Text, Record)] -> Double
damageScore srcs = flatImmediate + flatDot + pctImmediate + pctDot
  where
    flatImmediate = sum [snd (sumRange srcs ["offensive", "offensiveBase", "offensiveBonus"] stem) | (stem, _) <- damageElems]
    flatDot = sum [snd (sumRange srcs ["offensiveSlow"] stem) | (stem, _) <- dotElems]
    pctImmediate =
      sumField srcs "offensiveElementalModifier"
        + sum [sumField srcs ("offensive" <> stem <> "Modifier") | (stem, _) <- damageElems]
    pctDot = sum [sumField srcs ("offensiveSlow" <> stem <> "Modifier") | (stem, _) <- dotElems]

-- | The key flat (+ percent) totals contributed by a set of stat sources, as
-- @(label, flat, percent)@, keeping only those that contribute something.
keyTotalsOf :: [(Text, Record)] -> [(Text, Double, Double)]
keyTotalsOf sources =
  [ (label, flat, pct)
  | (label, flatField, pctField) <- keyStatFields
  , let flat = sumField sources flatField
        pct = maybe 0 (sumField sources) pctField
  , flat /= 0 || pct /= 0
  ]

-- (label, flat field, maybe percent-modifier field)
keyStatFields :: [(Text, Text, Maybe Text)]
keyStatFields =
  [ ("Offensive Ability", "characterOffensiveAbility", Just "characterOffensiveAbilityModifier")
  , ("Defensive Ability", "characterDefensiveAbility", Just "characterDefensiveAbilityModifier")
  , ("Armor", "defensiveProtection", Just "defensiveProtectionModifier")
  , ("Health", "characterLife", Just "characterLifeModifier")
  , ("Energy", "characterMana", Just "characterManaModifier")
  , ("Physique", "characterStrength", Just "characterStrengthModifier")
  , ("Cunning", "characterDexterity", Just "characterDexterityModifier")
  , ("Spirit", "characterIntelligence", Just "characterIntelligenceModifier")
  ]

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

capitalizeT :: Text -> Text
capitalizeT t = T.toUpper (T.take 1 t) <> T.drop 1 t

-- whole number, dropping a trailing ".0"
showN :: Double -> Text
showN x =
  let r = round x :: Integer
   in if fromIntegral r == x then T.pack (show r) else T.pack (show x)

-- signed whole number, e.g. "+320", "-15"
sign :: Double -> Text
sign x = if x > 0 then "+" <> showN x else showN x

rangeStr :: Double -> Double -> Text
rangeStr lo hi = if lo > 0 && lo /= hi then showN lo <> "-" <> showN hi else showN hi

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 0 (n - T.length t)) " "

rpad :: Int -> Text -> Text
rpad n t = T.replicate (max 0 (n - T.length t)) " " <> t

tshow :: Show a => a -> Text
tshow = T.pack . show

--------------------------------------------------------------------------------
-- Upgrade search
--------------------------------------------------------------------------------

-- | Relative weights for the upgrade score components.
data Weights = Weights
  { wResist :: !Double
  , wOa :: !Double
  , wDa :: !Double
  , wDamage :: !Double
  }
  deriving (Show, Eq)

-- | Defaults chosen to balance the components' natural scales (resist score is a
-- squared-shortfall in the thousands; OA/DA deltas are tens to hundreds; the
-- damage delta is a raw DPS change, often hundreds to thousands). Survivability
-- (resistances + defensive ability) is weighted well above raw damage, so a piece
-- that shores up a resist or DA hole beats one that only adds offence.
-- Resist is the priority: its term is the squared shortfall below the target, so
-- a swap that knocks a resist below cap costs far more than a marginal OA/DA gain
-- can return. OA/DA stay as light tie-breakers (a point of DA ~ a few points of
-- DPS), so they no longer override getting resistances to cap.
defaultWeights :: Weights
defaultWeights = Weights {wResist = 2, wOa = 4, wDa = 5, wDamage = 1}

-- | Set one weight by category name (resist|oa|da|damage); unknown names are ignored.
setWeight :: Text -> Double -> Weights -> Weights
setWeight cat v w = case cat of
  "resist" -> w {wResist = v}
  "oa" -> w {wOa = v}
  "da" -> w {wDa = v}
  "damage" -> w {wDamage = v}
  _ -> w

data UpgradeRow = UpgradeRow
  { urScore :: !Double
  , urName :: !Text
  , urLocation :: !Text -- where the candidate is (e.g. "shared stash")
  , urLevel :: !(Maybe Int)
  , urResists :: ![(Text, Double, Double)] -- (type, before, after), changed only
  , urOa :: !Double
  , urDa :: !Double
  , urDpsDelta :: !Double -- approx change to best-attack-plus-procs DPS
  , urItem :: !Item -- the candidate (for overlaying, e.g. its DPS)
  }
  deriving (Show, Eq)

-- | The conventional resistance target the upgrade search aims for (just below
-- the standard 80% cap so any shortfall is penalised).
defaultUpgradeTarget :: Double
defaultUpgradeTarget = 80

-- | Precomputed baseline against which alternative gear lists can be scored
-- cheaply, sharing the cost of the (relatively expensive) resist/key-total/DPS
-- evaluation of the base build. Build it once with 'mkScoreBase' and reuse for
-- many candidate overlays via 'scoreItems'.
data ScoreBase = ScoreBase
  { sbWeights :: !Weights
  , sbTarget :: !Double
  , sbDiff :: !Difficulty
  , sbDb :: !GameDb
  , sbChar :: !Character
  , sbExtra :: ![(Source, Record)] -- non-gear sources (devotions, mastery, buffs)
  , sbBaseResists :: ![(Text, Double, Double, Double)]
  , sbBaseKeyTotals :: ![(Text, Double, Double)]
  , sbBaseDps :: !Double
  }

-- | Precompute the baseline stats for an equipped gear list so candidate
-- overlays can be scored without redoing the base work each time.
mkScoreBase
  :: Weights -> Double -> Difficulty -> Character -> [(Source, Record)] -> GameDb -> [Item] -> ScoreBase
mkScoreBase w target diff c extra db base =
  let srcBase = statSources db base ++ extra
   in ScoreBase
        { sbWeights = w
        , sbTarget = target
        , sbDiff = diff
        , sbDb = db
        , sbChar = c
        , sbExtra = extra
        , sbBaseResists = resistRows diff (plainSources srcBase)
        , sbBaseKeyTotals = keyTotalsOf (plainSources srcBase)
        , sbBaseDps = estTotalDpsOf db c srcBase
        }

-- | The single number we treat as "damage" for upgrade scoring: the highest
-- active attack's DPS plus every always-on proc folded in (procs fire while
-- you attack), so its delta approximates the real change to sustained output.
estTotalDpsOf :: GameDb -> Character -> [(Source, Record)] -> Double
estTotalDpsOf db c src =
  let rows = attackDps db src c
      actives = filter ((== Active) . adKind) rows
      best = if null actives then 0 else maximum (map adDps actives)
   in best + sum [adDps r | r <- rows, adKind r == Triggered]

-- | Score an arbitrary alternative gear list against a precomputed baseline,
-- returning @(score, resist-changes, oa-delta, da-delta, dps-delta)@. The score
-- combines the weighted resist shortfall reduction with the OA/DA/DPS deltas.
scoreItems
  :: ScoreBase
  -> [Item]
  -> (Double, [(Text, Double, Double)], Double, Double, Double)
scoreItems sb over =
  let srcO = statSources (sbDb sb) over ++ sbExtra sb
      rO = resistRows (sbDiff sb) (plainSources srcO)
      kO = keyTotalsOf (plainSources srcO)
      pen x = let d = sbTarget sb - x in if d > 0 then d * d else 0
      paired = zip (sbBaseResists sb) rO
      changes = [(n, b, a) | ((n, b, _, _), (_, a, _, _)) <- paired, b /= a]
      resScore = sum [pen b - pen a | ((_, b, _, _), (_, a, _, _)) <- paired]
      flatOf l ks = case [f | (lab, f, _) <- ks, lab == l] of (x : _) -> x; [] -> 0
      oaD = flatOf "Offensive Ability" kO - flatOf "Offensive Ability" (sbBaseKeyTotals sb)
      daD = flatOf "Defensive Ability" kO - flatOf "Defensive Ability" (sbBaseKeyTotals sb)
      dpsD = estTotalDpsOf (sbDb sb) (sbChar sb) srcO - sbBaseDps sb
      w = sbWeights sb
      allResistsMaxed = all (\(_, a, _, _) -> a >= sbTarget sb) rO
      effectiveDamageWeight = if allResistsMaxed then wDamage w else 0
      sc = wResist w * resScore + wOa w * oaD + wDa w * daD + effectiveDamageWeight * dpsD
   in (sc, changes, oaD, daD, dpsD)

-- | Score each candidate as an overlay onto @base@, keeping net-positive results
-- best-first. Resistances use the non-linear squared-shortfall-below-@target@
-- weighting; OA/DA/damage use their deltas. @extra@ is the non-gear sources
-- (devotions, mastery, skill buffs), held constant across candidates. @slotOcc@
-- selects which equipped item of the candidate's slot type to replace (e.g. the
-- second ring), so symmetric slots can be compared independently.
findUpgrades :: Weights -> Double -> Difficulty -> Int -> Character -> [(Source, Record)] -> GameDb -> [Item] -> [(Text, Item)] -> [UpgradeRow]
findUpgrades w target diff slotOcc c extra db base candidates =
  sortOn (negate . urScore) [r | (loc, cand) <- candidates, let r = scoreOne loc cand, urScore r > 0]
  where
    sb = mkScoreBase w target diff c extra db base
    scoreOne loc cand =
      let over = overlayAt db slotOcc base cand
          (sc, changes, oaD, daD, dpsD) = scoreItems sb over
          attrs = itemAttrs cand db
       in UpgradeRow sc (iaDisplayName attrs) loc (iaLevelRequirement attrs) changes oaD daD dpsD cand

-- | Render one upgrade row: a header line naming the item and where it is, then
-- each resistance change on its own line (stacked for easy comparison), then a
-- single OA/DA/DPS summary. The DPS figure is the approximate change to your
-- best attack with all procs folded in. Resist lines are coloured by type when
-- @useColor@ is set.
renderUpgradeRow :: Bool -> UpgradeRow -> Text
renderUpgradeRow useColor r =
  T.unlines $
    ("  +" <> showScore (urScore r) <> "  lvl " <> lvl <> "  " <> urName r <> "  [" <> urLocation r <> "]")
      : map resLine (urResists r)
      ++ offLines
  where
    lvl = maybe "-" (T.pack . show) (urLevel r)
    resLine (n, b, a) =
      T.replicate 8 " "
        <> colorByType useColor (pad 16 n <> rpad 6 (showN b <> "%") <> " -> " <> rpad 6 (showN a <> "%") <> "  (" <> sign (a - b) <> ")")
    offLines =
      let parts =
            ["OA " <> sign (urOa r) | urOa r /= 0]
              ++ ["DA " <> sign (urDa r) | urDa r /= 0]
              ++ ["~DPS " <> sign (fromIntegral (round (urDpsDelta r) :: Integer)) | round (urDpsDelta r) /= (0 :: Integer)]
       in [T.replicate 8 " " <> "[" <> T.intercalate ", " parts <> "]" | not (null parts)]
    showScore x = T.pack (show (round x :: Integer))

--------------------------------------------------------------------------------
-- Attack DPS estimate
--------------------------------------------------------------------------------

-- | Assumed base weapon attack rate (attacks/sec) for spam attacks, since the
-- real per-weapon base speed lives in game data not in the extracted DB. Refine
-- when that data is available.
assumedBaseAttackSpeed :: Double
assumedBaseAttackSpeed = 1.0

-- | Whether a row is an attack you actively use (pick one to spam/cast) or a
-- proc that fires automatically while you attack (additive on top).
data AttackKind = Active | Triggered
  deriving (Show, Eq)

data AttackDps = AttackDps
  { adName :: !Text
  , adRank :: !(Maybe Int) -- Nothing for the bare weapon attack
  , adKind :: !AttackKind
  , adPerHit :: !Double
  , adDps :: !Double
  , adRate :: !Text -- human description of the rate used
  , adTypes :: ![(Text, Double)] -- per-type per-hit contribution
  }
  deriving (Show, Eq)

-- value of a possibly-array field at a rank index (clamped), else scalar.
atRank :: Int -> Value -> Double
atRank i v = case v of
  VList xs | not (null xs) -> num (xs !! min (max 0 i) (length xs - 1))
  _ -> num v
  where
    num (VInt n) = fromIntegral n
    num (VFloat f) = realToFrac f
    num _ = 0

--------------------------------------------------------------------------------
-- Resistance reduction (applied to enemies)
--------------------------------------------------------------------------------

-- | The three resistance-reduction buckets Grim Dawn tracks (there is no
-- per-element field the way there is for damage/resistance — only "all
-- resistances", "fire+cold+lightning together", and "physical"), each with
-- the mechanics it actually carries. Confirmed against the live game
-- database: Physical has no @...ResistanceReductionPercent...@ variant.
resistReductionTypes :: [(Text, Text, [Text])]
resistReductionTypes =
  [ ("Total", "Total", ["Absolute", "Percent"])
  , ("Elemental", "Elemental", ["Absolute", "Percent"])
  , ("Physical", "Physical", ["Absolute"])
  ]

-- a rank-indexed field lookup that stays Nothing when the field is absent,
-- unlike 'atRank' (which defaults a missing field to 0) — presence is what
-- decides whether a mechanic applies at all.
atRankField :: Int -> Text -> Record -> Maybe Double
atRankField i f r = atRank i <$> HM.lookup f r

-- | The resistance-reduction effects a single record grants, as fully
-- rendered fragments (no label prefix) — e.g. @"-30% Total Resistance (20%
-- chance, 5s)"@ or @"-20 Physical Resistance"@ (chance/duration are only
-- shown when the record actually carries them; most Elemental/Physical
-- reductions are always-on rather than proc-based). @i@ is the rank index
-- (0-based) for rank-scaled skill fields; gear/devotion records that are
-- never rank-scaled always pass 0.
resistReductionFragments :: Int -> Record -> [Text]
resistReductionFragments i r =
  [ fragment label isPct v chance dur
  | (label, stem, mechanics) <- resistReductionTypes
  , mechName <- mechanics
  , let base = "offensive" <> stem <> "ResistanceReduction" <> mechName
        isPct = mechName == "Percent"
  , Just v <- [atRankField i (base <> "Min") r]
  , v /= 0
  , let chance = atRankField i (base <> "Chance") r
        dur = atRankField i (base <> "DurationMin") r
  ]
  where
    fragment label isPct v chance dur =
      "-"
        <> showN (abs v)
        <> (if isPct then "%" else "")
        <> " "
        <> label
        <> " Resistance"
        <> suffix chance dur
    suffix (Just c) (Just d) = " (" <> showInt c <> "% chance, " <> oneDp d <> "s)"
    suffix (Just c) Nothing = " (" <> showInt c <> "% chance)"
    suffix Nothing (Just d) = " (" <> oneDp d <> "s)"
    suffix Nothing Nothing = ""
    showInt x = T.pack (show (round x :: Integer))

-- | Every resistance-reduction effect the character can apply to enemies,
-- one line per granting source (@"<source>: <effect>"@; a source with more
-- than one effect gets one line per effect). Scans equipped gear (base +
-- affixes + relic + augment + active set-tiers, via 'statSources') and
-- *every* invested skill node — devotion stars, mastery bars, and
-- playerclass skills (attacks, passives, and their modifiers/transmuters)
-- alike — since in practice the most common source of resistance reduction
-- is an attack skill's own modifier (e.g. Reprisal, Field Command), which
-- the narrower "buff" source pool 'skillSources' deliberately excludes.
-- Skill values are rank-aware (using each skill's effective invested rank,
-- the same @+skill levels@ scaling used elsewhere); gear/devotion records
-- are never rank-scaled, so they're always read at index 0.
resistReductionLines :: GameDb -> [Item] -> Character -> [Text]
resistReductionLines db items c =
  -- A devotion celestial power's granted "_skill" proc record often mirrors
  -- the exact same field(s) as its constellation's own passive star record
  -- (both resolve to the same display name too), which would otherwise
  -- render as an identical line twice. Deduping the final rendered lines is
  -- safer than trying to exclude specific record shapes up front: it can
  -- only ever merge two lines that already say the same thing, never drop a
  -- genuinely distinct effect.
  nub (concatMap lineFor gearEntries ++ concatMap lineFor skillEntries)
  where
    gear = statSources db items
    gearEntries = [(srcLabel s, 0, r) | (s, r) <- gear]
    lv = collectSkillLevels (plainSources gear)
    skillEntries =
      [ (skillDisplayName db (skName s), rankWith lv s - 1, r)
      | s <- charSkills c
      , skLevel s > 0
      , Just r <- [lookupRecord (skName s) db]
      ]
    lineFor (label, i, r) = [label <> ": " <> frag | frag <- resistReductionFragments i r]

-- | Estimate per-hit damage and DPS for each invested attack skill, given the
-- character's effective stat @sources@ (gear + buffs). Pipeline per type: the
-- skill's @weaponDamagePct@ scales (total flat weapon damage + the retaliation
-- added to attack via @retaliationDamagePct@); the skill's own @offensive*@ adds
-- on top; damage-type conversions then apply; finally the @%@ damage modifiers.
-- A primary attack folds in its invested transmuters/modifiers/secondaries
-- (same base name): their added flat damage, weapon%, conversions,
-- @retaliationDamagePct@ (e.g. Reprisal), and flat cooldown changes (e.g.
-- Tectonic Shift). Other primary attacks sharing a base (the weapon-pool
-- attacks) stay separate. Damage-over-time is added as a per-application total
-- (per-second x duration) which, since DoTs stack, contributes at the attack
-- rate; chance-based cooldown resets count as expected value. A bare
-- "Weapon Attack" row (100% weapon damage, no skill) is included as a baseline.
--
-- Rows come in two kinds. 'Active' attacks (above) are ones you pick between.
-- 'Triggered' procs fire automatically while you attack and are additive: skills
-- granted by gear (@itemSkillName@ + a @cast_\@...@ controller), procs bound to
-- devotion stars (@templateAutoCast@), and learned on-hit skills
-- (@onHitActivationChance@, e.g. Vindictive Flame). A proc's expected DPS is
-- @perHit / (cooldown + 1/(chance x attacks-per-second))@ — the cooldown plus the
-- geometric wait for the next successful roll. Proc damage is flat (not weapon
-- scaled) but still gets your conversions and @%@ modifiers. Only attack-driven
-- triggers are modelled (on attack/hit/melee); on-crit/block/kill/low-health and
-- persistent multi-hit ground effects are skipped or counted as a single hit.
-- No crit or enemy resistances.
attackDps :: GameDb -> [(Source, Record)] -> Character -> [AttackDps]
attackDps db sources0 c = map rdSummary (attackDpsRows Nothing db sources0 c)

-- | Every attack/proc row's full detail (see 'RowDetail'). @exclude@, when
-- set, removes every record tagged with that 'srcKey' from both the sources
-- list and any skill sibling before computing — used by 'attackDpsBreakdown'
-- to measure a single source's DPS impact by recomputing without it.
attackDpsRows :: Maybe Text -> GameDb -> [(Source, Record)] -> Character -> [RowDetail]
attackDpsRows exclude db sources0 c =
  sortOn (negate . adDps . rdSummary) actives ++ sortOn (negate . adDps . rdSummary) procs
  where
    sources = filter (\(s, _) -> Just (srcKey s) /= exclude) sources0
    excluded sk = Just sk == exclude
    actives = [r | m <- weaponRow : map compute (charSkills c), Just r <- [m]]
    procs = [r | m <- map computeWps (charSkills c) ++ itemProcs ++ devoProcs ++ onHitProcs, Just r <- [m]]
    lv = collectSkillLevels (plainSources sources)
    -- conversions from gear/buffs apply to every skill
    globalConv = concatMap (recordConversions . snd) sources
    -- The retaliation-added-to-attack chain, keyed by raw stem token (e.g.
    -- "Fire"): each stem's own flat retaliation stat (x its own % modifiers)
    -- and the shared "% of retaliation damage added to attack" (global gear/
    -- buff sources plus any sibling skill's own value, e.g. Reprisal). This
    -- is the single computation both 'typedDamage' (feeding the aggregate
    -- flat term via 'rawFlatVectors') and 'attackDpsBreakdown' use, so the
    -- two can never disagree.
    retaliationByStem :: [(Source, Record)] -> [(Source, Int, Record)] -> HM.HashMap Text RetaliationTypeDetail
    retaliationByStem srcs sibs =
      HM.fromList
        [ (stem, d)
        | (stem, tok) <- damageElems
        , let d = mkDetail stem (effectDisplay ["offensive"] tok)
        , rtdFlatSubtotal d /= 0 || rtdAddedToAttack d /= 0
        ]
      where
        addContribs = retaliationAddToAttack srcs sibs
        addTotal = sum (map saValue addContribs)
        mkDetail stem lbl =
          RetaliationTypeDetail
            { rtdLabel = lbl
            , rtdFlatSources = flatContribs
            , rtdFlatSubtotal = flatSubtotal
            , rtdPercentSources = pctContribs
            , rtdTotalPercent = pctTotal
            , rtdRetaliationDamage = retalDamage
            , rtdAddedToAttack = retalDamage * addTotal / 100
            }
          where
            flatContribs =
              [ SourceAmount s v
              | (s, r) <- srcs
              , let (lo, hi) = sumRange [(srcKey s, r)] ["retaliation"] stem
                    v = (lo + hi) / 2
              , v /= 0
              ]
            flatSubtotal = sum (map saValue flatContribs)
            pctContribs =
              [ SourceAmount s v
              | (s, r) <- srcs
              , let v =
                      fromMaybe 0 (recNum r ("retaliation" <> stem <> "Modifier"))
                        + fromMaybe 0 (recNum r "retaliationTotalDamageModifier")
              , v /= 0
              ]
            pctTotal = sum (map saValue pctContribs)
            retalDamage = flatSubtotal * (1 + pctTotal / 100)
    retaliationAddToAttack :: [(Source, Record)] -> [(Source, Int, Record)] -> [SourceAmount]
    retaliationAddToAttack srcs sibs =
      [SourceAmount s v | (s, r) <- srcs, let v = fromMaybe 0 (recNum r "retaliationDamagePct"), v /= 0]
        ++ [SourceAmount s v | (s, i, r) <- sibs, let v = maybe 0 (atRank i) (HM.lookup "retaliationDamagePct" r), v /= 0]
    -- expected % cooldown reduction from a record at rank i: a flat reduction, or
    -- (reduction x chance) when it is a chance-based reset (e.g. Reprisal).
    cdrContrib i r =
      let red = maybe 0 (atRank i) (HM.lookup "skillCooldownReduction" r)
       in case HM.lookup "skillCooldownReductionChance" r of
            Just _ -> red * maybe 0 (atRank i) (HM.lookup "skillCooldownReductionChance" r) / 100
            Nothing -> red
    aggIn recs key = sum [maybe 0 (atRank i) (HM.lookup key r) | (i, r) <- recs]
    -- Rate-affecting factors, each exposing its own source-attributed
    -- contributor list alongside the scalar 'attackDps'/'mkRow' need, so
    -- both the summary and the breakdown are derived from one computation.
    attackSpeedCalc =
      let contribs = [SourceAmount s v | (s, r) <- sources, let v = fromMaybe 0 (recNum r "characterAttackSpeedModifier"), v /= 0]
          total = sum (map saValue contribs)
          eff = assumedBaseAttackSpeed * (1 + total / 100)
       in RateFactorDetail "Attack Speed" assumedBaseAttackSpeed contribs eff (oneDp assumedBaseAttackSpeed <> " x (1 + " <> showInt total <> "%) = " <> oneDp eff <> "/s")
    cooldownReductionCalc baseCd sibs =
      let gearContribs = [SourceAmount s v | (s, r) <- sources, let v = cdrContrib 0 r, v /= 0]
          sibContribs = [SourceAmount s v | (s, i, r) <- sibs, let v = cdrContrib i r, v /= 0]
          contribs = gearContribs ++ sibContribs
          total = sum (map saValue contribs)
          eff = max 0.1 (baseCd * (1 - total / 100))
       in RateFactorDetail "Cooldown Reduction" baseCd contribs eff (oneDp baseCd <> "s x (1 - " <> showInt total <> "%) = " <> oneDp eff <> "s")
    weaponDamagePctCalc sibs =
      let contribs = [SourceAmount s v | (s, i, r) <- sibs, let v = maybe 0 (atRank i) (HM.lookup "weaponDamagePct" r), v /= 0]
          total = sum (map saValue contribs)
       in RateFactorDetail "Weapon Damage %" 0 contribs total (showInt total <> "% weapon damage")
    -- the row-level retaliation-added-to-attack detail, from the same
    -- 'retaliationByStem'/'retaliationAddToAttack' 'typedDamage' uses.
    retaliationDetailFor srcs sibs
      | HM.null byStem = Nothing
      | otherwise = Just (RetaliationDetail addContribs (sum (map saValue addContribs)) (HM.elems byStem))
      where
        byStem = retaliationByStem srcs sibs
        addContribs = retaliationAddToAttack srcs sibs
    -- the lowercased template name of a record
    tmpl r = maybe "" T.toLower (HM.lookup "templateName" r >>= valueText)
    -- a primary attack emits a row; its transmuters/modifiers/secondaries fold in.
    isPrimary r = not (any (`T.isInfixOf` tmpl r) ["secondary", "modifier", "transmuter", "passive", "buff"])
    -- a skill that fires on hit/attack (e.g. Vindictive Flame) — a proc, not an
    -- attack you actively use.
    isOnHit r = "onhit" `T.isInfixOf` tmpl r
    -- a weapon-pool skill (WPS, e.g. Bursting Round): has a per-rank chance to
    -- replace your attack swing (skillChanceWeight). Unlike a default-attack
    -- replacer (Fire Strike, Cadence) it stacks on top of whatever you spam.
    isWps r = HM.member "skillChanceWeight" r
    compute s
      | not ("records/skills/playerclass" `T.isPrefixOf` skName s) = Nothing
      | skLevel s <= 0 = Nothing
      | otherwise = case lookupRecord (skName s) db of
          Just r | isPrimary r && not (isOnHit r) && not (isWps r) -> emit s
          _ -> Nothing
    computeWps s
      | not ("records/skills/playerclass" `T.isPrefixOf` skName s) = Nothing
      | skLevel s <= 0 = Nothing
      | otherwise = case lookupRecord (skName s) db of
          Just r | isPrimary r && not (isOnHit r) && isWps r -> emitWps s r
          _ -> Nothing
    -- this skill plus its invested *non-primary* siblings (transmuters, modifiers,
    -- secondaries that share its base name) — other primary attacks that happen to
    -- share a base (e.g. the weapon-pool attacks) are kept separate.
    sibsOf s =
      [ (mkSource (skName sib) SrcSkill (skillDisplayName db (skName sib)), rankWith lv sib - 1, rr)
      | sib <- charSkills c
      , not (excluded (skName sib))
      , skillBase (skName sib) == skillBase (skName s)
      , skLevel sib > 0
      , Just rr <- [lookupRecord (skName sib) db]
      , skName sib == skName s || not (isPrimary rr)
      ]
    emit s =
      let sibs = sibsOf s
          sibs2 = map (\(_, i, rr) -> (i, rr)) sibs
       in mkRow (skillDisplayName db (skName s)) (Just (rankWith lv s)) (aggIn sibs2 "weaponDamagePct") (aggIn sibs2 "skillCooldownTime") sibs
    -- a WPS row: weapon-scaled per-hit like an attack, but contributing only on
    -- the @chance@ fraction of swings it replaces, so it adds to your spammed
    -- attack rather than being an alternative to it.
    emitWps s r =
      let sibs = sibsOf s
          rank = rankWith lv s
          chance = maybe 0 (atRank (rank - 1)) (HM.lookup "skillChanceWeight" r) / 100
          wdpCalc = weaponDamagePctCalc sibs
          typed = typedDamage (rfdEffective wdpCalc) sibs
          perHit = sum (map tdTotal typed)
          rate = showInt (chance * 100) <> "% WPS on attack"
       in if perHit <= 0 || chance <= 0
            then Nothing
            else
              Just
                RowDetail
                  { rdSummary = AttackDps (skillDisplayName db (skName s)) (Just rank) Triggered perHit (perHit * chance * rfdEffective attackSpeedCalc) rate [(tdLabel t, tdTotal t) | t <- typed]
                  , rdTypes = typed
                  , rdRetaliation = retaliationDetailFor sources sibs
                  , rdRateFactors = [attackSpeedCalc, wdpCalc]
                  , rdTrigger = Nothing
                  -- excludes the row's own primary skill record from the
                  -- impact-ranking pool (see the note on mkRow's
                  -- rdSourcesTouched below) — its invested modifiers/
                  -- transmuters stay, since those are genuine build choices.
                  , rdSourcesTouched = nub (map fst sources ++ [s' | (s', _, rr) <- sibs, not (isPrimary rr)])
                  }
    -- the bare auto-attack: 100% weapon damage, no skill, spammed at attack speed
    weaponRow = mkRow "Weapon Attack" Nothing 100 0 []
    -- Every source's raw (pre-conversion) flat contribution across damage
    -- stems, before % modifiers: gear/weapon sources (wpnPct-scaled), skill/
    -- modifier sources (their own flat, unscaled — matches the old `sflat`),
    -- and the retaliation-added-to-attack pseudo-source. One vector per
    -- source so conversions (a linear redistribution) can be applied
    -- per-source and still sum to the correct aggregate.
    rawFlatVectors :: Double -> [(Source, Int, Record)] -> [(Source, HM.HashMap Text Double)]
    rawFlatVectors wpnPct sibs =
      [ (s, vec)
      | (s, r) <- sources
      , let vec =
              HM.fromList
                [ (stem, v)
                | (stem, _) <- damageElems
                , let (lo, hi) = sumRange [(srcKey s, r)] ["offensive", "offensiveBase", "offensiveBonus"] stem
                      v = (lo + hi) / 2 * wpnPct / 100
                , v /= 0
                ]
      , not (HM.null vec)
      ]
        ++ [ (s, vec)
           | (s, i, r) <- sibs
           , let vec =
                   HM.fromList
                     [ (stem, v)
                     | (stem, _) <- damageElems
                     , let v =
                             ( maybe 0 (atRank i) (HM.lookup ("offensive" <> stem <> "Min") r)
                                 + maybe 0 (atRank i) (HM.lookup ("offensive" <> stem <> "Max") r)
                             )
                               / 2
                     , v /= 0
                     ]
           , not (HM.null vec)
           ]
        ++ [ (retaliationPseudoSource, HM.map rtdAddedToAttack byStem)
           | let byStem = retaliationByStem sources sibs
           , not (HM.null byStem)
           ]
    -- Every source's raw (pre-conversion) DoT contribution across every DoT
    -- stem (per-application total: (min+max)/2 x duration), before duration/
    -- damage % modifiers. Built across *all* stems per source (not just the
    -- stem currently being reported) so a conversion — which can move a
    -- source's contribution from one stem to another — has the origin
    -- stem's raw value available when converting.
    rawDotVectors :: Double -> [(Source, Int, Record)] -> [(Source, HM.HashMap Text Double)]
    rawDotVectors wpnPct sibs =
      [ (s, vec)
      | (s, r) <- sources
      , let vec = HM.fromList [(stem, v) | (stem, _) <- dotElems, let v = perRec stem (0, r) * wpnPct / 100, v /= 0]
      , not (HM.null vec)
      ]
        ++ [ (s, vec)
           | (s, i, r) <- sibs
           , let vec = HM.fromList [(stem, v) | (stem, _) <- dotElems, let v = perRec stem (i, r), v /= 0]
           , not (HM.null vec)
           ]
      where
        perRec stem (i, r) =
          ( maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Min") r)
              + maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Max") r)
          )
            / 2
            * maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "DurationMin") r)
    -- The per-type per-application damage for a group of contributing records
    -- @sibs@ (rank-indexed), with weapon damage scaling @wpnPct@: weapon flat (from
    -- gear in @sources@) + retaliation-added, x weapon%, plus the records' own flat;
    -- conversions; then % damage modifiers. Plus the stacking-DoT term. The weapon
    -- attack and skills pass @wpnPct@/@sibs@; procs pass @wpnPct = 0@ and the single
    -- proc record (its damage is flat, not weapon-scaled).
    typedDamage :: Double -> [(Source, Int, Record)] -> [TypeDetail]
    typedDamage wpnPct sibs =
      [ TypeDetail
          { tdLabel = lbl
          , tdTotal = total
          , tdFlatSources = flatContribs
          , tdFlatSubtotal = flatSubtotal
          , tdPercentSources = pctContribs
          , tdTotalPercent = pctTotal
          , tdDurationSources = []
          , tdTotalDurationPercent = 0
          , tdDamagePctSources = []
          , tdTotalDamagePercent = 0
          }
      | (stem, tok) <- damageElems
      , let lbl = effectDisplay ["offensive"] tok
            convs = globalConv ++ concatMap (recordConversions . (\(_, _, r) -> r)) sibs
            convVecs = [(s, applyConversions convs v) | (s, v) <- rawFlatVectors wpnPct sibs]
            flatContribs = [SourceAmount s v | (s, vec) <- convVecs, let v = HM.lookupDefault 0 stem vec, v /= 0]
            flatSubtotal = sum (map saValue flatContribs)
            pctContribs =
              [ SourceAmount s v
              | (s, r) <- sources
              , let v = fromMaybe 0 (recNum r ("offensive" <> stem <> "Modifier")) + fromMaybe 0 (recNum r "offensiveTotalDamageModifier")
              , v /= 0
              ]
            pctTotal = sum (map saValue pctContribs)
            total = flatSubtotal * (1 + pctTotal / 100)
      , total >= 1
      ]
        ++ [ TypeDetail
              { tdLabel = effectDisplay ["offensive", "slow"] tok <> " (dot)"
              , tdTotal = total
              , tdFlatSources = flatContribs
              , tdFlatSubtotal = flatSubtotal
              , tdPercentSources = []
              , tdTotalPercent = 0
              , tdDurationSources = durContribs
              , tdTotalDurationPercent = durTotal
              , tdDamagePctSources = dmgContribs
              , tdTotalDamagePercent = dmgTotal
              }
           | (stem, tok) <- dotElems
           , let dotRecs = srcRecsFor sources ++ sibs
                 convs = globalConv ++ concatMap (recordConversions . (\(_, _, r) -> r)) sibs
                 convVecs = [(s, applyConversions convs v) | (s, v) <- rawDotVectors wpnPct sibs]
                 flatContribs = [SourceAmount s v | (s, vec) <- convVecs, let v = HM.lookupDefault 0 stem vec, v /= 0]
                 flatSubtotal = sum (map saValue flatContribs)
                 durContribs =
                   [ SourceAmount s v
                   | (s, i, r) <- dotRecs
                   , let v = maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "DurationModifier") r)
                   , v /= 0
                   ]
                 durTotal = sum (map saValue durContribs)
                 dmgContribs =
                   [SourceAmount s v | (s, r) <- sources, let v = fromMaybe 0 (recNum r "offensiveTotalDamageModifier"), v /= 0]
                     ++ [ SourceAmount s v
                        | (s, i, r) <- dotRecs
                        , let v = maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Modifier") r)
                        , v /= 0
                        ]
                 dmgTotal = sum (map saValue dmgContribs)
                 total = flatSubtotal * (1 + durTotal / 100) * (1 + dmgTotal / 100)
           , total >= 1
           ]
      where
        srcRecsFor srcs = [(s, 0 :: Int, r) | (s, r) <- srcs]
    -- an actively-used attack (skill group or weapon attack): spam at attack speed
    -- (weapon%) or once per cooldown.
    mkRow name mRank wpnPct cdBase sibs =
      let cdrCalc = cooldownReductionCalc cdBase sibs
          cd = rfdEffective cdrCalc
          typed = typedDamage wpnPct sibs
          perHit = sum (map tdTotal typed)
          retal = retaliationDetailFor sources sibs
          (dps, rate, rateFactors)
            | cdBase > 0 = (perHit / cd, oneDp cd <> "s cooldown", [cdrCalc])
            | wpnPct > 0 =
                ( perHit * rfdEffective attackSpeedCalc
                , "~" <> oneDp (rfdEffective attackSpeedCalc) <> "/s attacks (assumed base)"
                , [attackSpeedCalc, weaponDamagePctCalc sibs]
                )
            | otherwise = (0, "", [])
       in if perHit <= 0 || T.null rate
            then Nothing
            else
              Just
                RowDetail
                  { rdSummary = AttackDps name mRank Active perHit dps rate [(tdLabel t, tdTotal t) | t <- typed]
                  , rdTypes = typed
                  , rdRetaliation = retal
                  , rdRateFactors = rateFactors
                  , rdTrigger = Nothing
                  -- excludes the row's own primary skill record: "what if I
                  -- hadn't invested in this skill" is tautological while
                  -- viewing this skill's own breakdown (it would always show
                  -- the largest possible impact, the row's entire DPS,
                  -- trivialising the ranking). Its invested modifiers/
                  -- transmuters stay, since those are genuine build choices
                  -- independent of having the base skill at all.
                  , rdSourcesTouched = nub (map fst sources ++ [s | (s, _, rr) <- sibs, not (isPrimary rr)])
                  }
    -- a proc: fires automatically on attack/hit at chance @p@, no more than once
    -- per cooldown. Expected interval = cooldown + the geometric wait for the next
    -- successful roll (@1 / (p x attacks-per-second)@). Damage is flat (no weapon
    -- scaling). @rank@ is the granted/invested level used to index value arrays.
    -- @grantedBy@ is the single source that grants this proc (an item, a
    -- devotion star, or the learned skill itself), used both as the trigger's
    -- display label and as the tag on the proc's own damage record, so its
    -- flat contributor list shows exactly one line: the granting source.
    mkProc name rank rec p cd trig grantedBy =
      let typed = typedDamage 0 [(grantedBy, rank - 1, rec)]
          perHit = sum (map tdTotal typed)
          interval = cd + 1 / max 0.01 (p * rfdEffective attackSpeedCalc)
          rate = showInt (p * 100) <> "% on " <> trig <> ", " <> oneDp cd <> "s cd"
       in if perHit <= 0
            then Nothing
            else
              Just
                RowDetail
                  { rdSummary = AttackDps name Nothing Triggered perHit (perHit / interval) rate [(tdLabel t, tdTotal t) | t <- typed]
                  , rdTypes = typed
                  , rdRetaliation = Nothing
                  , rdRateFactors = []
                  , rdTrigger = Just (TriggerDetail (p * 100) cd (srcLabel grantedBy))
                  -- same exclusion as mkRow: the granting source defines the
                  -- proc's existence (removing it makes the whole proc
                  -- vanish, not just shrink), so it's excluded from its own
                  -- impact ranking — already surfaced via the trigger's
                  -- "granted by" line. Other gear/devotion/buff sources that
                  -- contribute generic %-modifiers to this proc's damage
                  -- stay, since those are genuine independent "what if"
                  -- questions (e.g. "what if I remove my +Fire% ring").
                  , rdSourcesTouched = nub (map fst sources) \\ [grantedBy]
                  }
    showInt x = T.pack (show (round x :: Integer))
    levelOf v = maybe 1 id (v >>= valueText >>= (readMaybe . T.unpack))
    -- procs granted by equipped items (itemSkillName + a cast_@... controller)
    itemProcs =
      [ mkProc (skillDisplayName db skn) rank rec p cd trig grantedBy
      | (skn, ir, grantedBy) <-
          nubBy (\(a, _, _) (b, _, _) -> a == b)
            [(s, ir, srcOfIr) | (srcOfIr, ir) <- sources, not (excluded (srcKey srcOfIr)), Just s <- [lookupField "itemSkillName" ir >>= valueText]]
      , Just rec <- [lookupRecord skn db]
      , Just (trig, p) <- [lookupField "itemSkillAutoController" ir >>= valueText >>= parseProcController]
      , let rank = levelOf (lookupField "itemSkillLevelEq" ir)
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
    -- procs bound to invested devotion stars (templateAutoCast controller)
    devoProcs =
      [ mkProc (skillDisplayName db (skName s)) rank rec p cd trig (mkSource (skName s) SrcDevotion (skillDisplayName db (skName s)))
      | s <- charSkills c
      , not (excluded (skName s))
      , "skills/devotion" `T.isInfixOf` skName s
      , skLevel s > 0
      , Just rec <- [lookupRecord (skName s) db]
      , Just (trig, p) <- [lookupField "templateAutoCast" rec >>= valueText >>= parseProcController]
      , let rank = rankWith lv s
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
    -- learned skills that fire on hit (Skill_OnHit*), e.g. Vindictive Flame
    onHitProcs =
      [ mkProc (skillDisplayName db (skName s)) rank rec p cd "hit" (mkSource (skName s) SrcSkill (skillDisplayName db (skName s)))
      | s <- charSkills c
      , not (excluded (skName s))
      , "records/skills/playerclass" `T.isPrefixOf` skName s
      , skLevel s > 0
      , Just rec <- [lookupRecord (skName s) db]
      , isOnHit rec
      , let rank = rankWith lv s
      , let p = maybe 1 (/ 100) (recNum rec "onHitActivationChance")
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]

-- | The full source-attributed breakdown for one attack/proc row, identified
-- by name + optional rank + kind (matching an 'AttackDps' row 'attackDps'
-- already returns). Each source's DPS impact is measured by recomputing
-- 'attackDpsRows' with that source excluded — an independent counterfactual
-- against the same baseline, not a decomposition (see the design doc's "Why
-- flat and % stay separate").
attackDpsBreakdown :: GameDb -> [(Source, Record)] -> Character -> Text -> Maybe Int -> AttackKind -> Maybe AttackBreakdown
attackDpsBreakdown db sources c name rank kind =
  toBreakdown <$> find matches (attackDpsRows Nothing db sources c)
  where
    -- identifies the requested row exactly (name+rank+kind), matching the
    -- specific card the user clicked.
    matches rd = adName (rdSummary rd) == name && adRank (rdSummary rd) == rank && adKind (rdSummary rd) == kind
    -- identifies "the same attack" in a with-one-source-excluded recompute,
    -- deliberately *not* requiring the same rank: many sources (gear/set
    -- bonuses granting "+N to all skills" or "+N to a mastery") shift a
    -- skill's effective rank by a point or two, which is a real, modest DPS
    -- change -- not the row vanishing. Matching on the exact original rank
    -- here would make the lookup fail for any such source (dpsWithout = 0),
    -- inflating its reported "impact" to the row's entire DPS.
    sameAttack rd = adName (rdSummary rd) == name && adKind (rdSummary rd) == kind
    toBreakdown rd =
      AttackBreakdown
        { abName = adName (rdSummary rd)
        , abRank = adRank (rdSummary rd)
        , abKind = adKind (rdSummary rd)
        , abPerHit = adPerHit (rdSummary rd)
        , abDps = adDps (rdSummary rd)
        , abRate = adRate (rdSummary rd)
        , abSourcesByImpact = sortOn (negate . abs . siDpsImpact) (filter ((/= 0) . siDpsImpact) (map (impactOf rd) (rdSourcesTouched rd)))
        , abTypes = rdTypes rd
        , abRetaliation = rdRetaliation rd
        , abRateFactors = rdRateFactors rd
        , abTrigger = rdTrigger rd
        }
    impactOf rd s =
      let rowsWithout = attackDpsRows (Just (srcKey s)) db sources c
          dpsWithout = case find sameAttack rowsWithout of
            Just rd' -> adDps (rdSummary rd')
            Nothing -> 0
       in SourceImpact s (adDps (rdSummary rd) - dpsWithout)

-- a number to one decimal place (e.g. cooldown seconds, attacks/sec)
oneDp :: Double -> Text
oneDp x = T.pack (show (fromIntegral (round (x * 10) :: Integer) / 10 :: Double))

-- | Damage-type conversions @(from-stem, to-stem, percent)@ declared by a record
-- (@conversionInType<i>@ / @conversionOutType<i>@ / @conversionPercentage<i>@).
-- Only single-type conversions between known damage stems are handled (the
-- "Elemental", "Stun", and multi-type list forms are skipped).
recordConversions :: Record -> [(Text, Text, Double)]
recordConversions r =
  [ (inT, outT, p)
  | i <- ["", "2", "3", "4", "5", "6"]
  , Just inT <- [HM.lookup ("conversionInType" <> i) r >>= valueText]
  , Just outT <- [HM.lookup ("conversionOutType" <> i) r >>= valueText]
  , inT `elem` convStems
  , outT `elem` convStems
  , Just p <- [recNum r ("conversionPercentage" <> i)]
  , p > 0
  ]
  where
    convStems = map fst damageElems

-- | Apply conversions to a per-stem flat-damage map: each converted chunk leaves
-- the source stem and is added to the destination (which then gets the
-- destination type's % modifiers downstream). Conversions out of a type are
-- taken from the pre-conversion amount and capped at 100% total per source type.
applyConversions :: [(Text, Text, Double)] -> HM.HashMap Text Double -> HM.HashMap Text Double
applyConversions convs flat0 =
  foldl (\m (k, d) -> HM.insertWith (+) k d m) flat0 (concatMap perFrom froms)
  where
    froms = nub [f | (f, _, _) <- convs]
    perFrom f =
      let cs = [(t, p) | (f', t, p) <- convs, f' == f]
          sumP = sum (map snd cs)
          factor = if sumP > 100 then 100 / sumP else 1
          avail = HM.lookupDefault 0 f flat0
          outs = [(t, avail * p * factor / 100) | (t, p) <- cs]
       in (f, negate (sum (map snd outs))) : outs

-- | Render the DPS estimate rows (best first). Per-type damage is coloured by
-- type when @useColor@ is set.
-- | Render the DPS rows in two groups — the attacks you pick between, and the
-- procs that fire automatically on top — followed by an estimated total (best
-- single attack + all procs).
renderDps :: Bool -> [AttackDps] -> Text
renderDps useColor rows =
  T.unlines (intercalate [""] (filter (not . null) [block "Attacks (pick one):" actives, block "Procs (auto, while attacking):" procRows, combined]))
  where
    actives = filter ((== Active) . adKind) rows
    procRows = filter ((== Triggered) . adKind) rows
    block title rs = if null rs then [] else title : concatMap fmt rs
    combined
      | null actives = []
      | otherwise =
          let best = maximum (map adDps actives)
              procSum = sum (map adDps procRows)
           in [ "Estimated total: best attack ~"
                  <> showI best
                  <> (if null procRows then "" else " + procs ~" <> showI procSum)
                  <> " = ~"
                  <> showI (best + procSum)
                  <> " dps"
              ]
    fmt r =
      [ "  "
          <> pad 30 (adName r <> maybe "" (\n -> " (" <> tshow n <> ")") (adRank r))
          <> "per-hit ~"
          <> rpad 7 (showI (adPerHit r))
          <> "  ~"
          <> rpad 7 (showI (adDps r))
          <> " dps  ("
          <> adRate r
          <> ")"
      , T.replicate 8 " " <> T.intercalate "; " (map seg (adTypes r))
      ]
    seg (t, d) = colorByType useColor (t <> " ~" <> showI d)
    showI x = T.pack (show (round x :: Integer))

-- | Parse a proc controller path like @.../cast_\@enemyonattack_20%.dbr@ into an
-- (attack-driven trigger label, chance fraction). Returns Nothing for triggers
-- not driven by your attack rate (on block/kill/low-health) or that need crit
-- (on-attack-crit), which the estimate does not model.
parseProcController :: Text -> Maybe (Text, Double)
parseProcController path = (,) <$> trig <*> chance
  where
    leaf = T.toLower (T.takeWhileEnd (/= '/') path)
    chance = case T.breakOn "%" leaf of
      (pre, suf)
        | T.null suf -> Nothing
        | otherwise -> (\n -> n / 100) <$> (readMaybe (T.unpack (T.takeWhileEnd isDigit pre)) :: Maybe Double)
    trig
      | "onattackcrit" `T.isInfixOf` leaf = Nothing
      | "onattack" `T.isInfixOf` leaf = Just "attack"
      | "onanyhit" `T.isInfixOf` leaf = Just "hit"
      | "onmeleehit" `T.isInfixOf` leaf = Just "melee hit"
      | otherwise = Nothing
