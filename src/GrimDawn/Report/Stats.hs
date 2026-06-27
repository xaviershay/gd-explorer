-- | Aggregated character stat totals from equipped gear (and, via the supplied
-- item list, any overlaid candidate gear): resistances with their cap and the
-- difficulty penalty, offensive/defensive ability, key defensive totals, weapon
-- damage, and total damage bonuses.
module GrimDawn.Report.Stats
  ( Difficulty (..)
  , parseDifficulty
  , difficultyPenalty
  , statSources
  , devotionSources
  , masterySources
  , BuffToggle (..)
  , noBuffs
  , parseBuffs
  , skillSources
  , overlay
  , overlayAt
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
    -- * Attack DPS estimate
  , assumedBaseAttackSpeed
  , AttackKind (..)
  , AttackDps (..)
  , attackDps
  , parseProcController
  , renderDps
  ) where

import Data.Char (isDigit, isLower, toLower)
import qualified Data.HashMap.Strict as HM
import Data.List (intercalate, nub, nubBy, sortOn)
import Data.Maybe (listToMaybe)
import Text.Read (readMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Arz (Record, Value (..), lookupField, valueText)
import GrimDawn.Db (GameDb, lookupRecord)
import GrimDawn.Gdc (Character (..), Item (..), Skill (..), emptyItemName)
import GrimDawn.Item
  ( damageElems
  , damageBonuses
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
-- Difficulty
--------------------------------------------------------------------------------

-- | Difficulty determines the flat resistance penalty applied to the character.
data Difficulty = Normal | Elite | Ultimate
  deriving (Show, Eq)

-- | The all-resistance penalty for a difficulty (Normal 0, Elite -25, Ultimate -50).
difficultyPenalty :: Difficulty -> Double
difficultyPenalty Normal = 0
difficultyPenalty Elite = 25
difficultyPenalty Ultimate = 50

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

-- | Every stat-bearing record contributed by a character's equipped gear: each
-- item's related records (base + affixes + relic + augment) plus each active set
-- bonus tier. (Devotion and skill buffs are layered on by callers later.)
statSources :: GameDb -> [Item] -> [(Text, Record)]
statSources db items =
  concatMap (`relatedRecords` db) equipped ++ setTiers
  where
    equipped = filter (not . emptyItemName) items
    setRecs = [s | it <- equipped, Just s <- [setRecordName it db]]
    setTiers =
      [ (rec, resolveSetTier cnt r)
      | rec <- nub setRecs
      , Just r <- [lookupRecord rec db]
      , let cnt = length (filter (== rec) setRecs)
      ]

-- | Passive stat records granted by a character's chosen devotions: each taken
-- constellation star (excluding the @*_skill@ celestial-power procs, which are
-- granted skills rather than always-on passives).
devotionSources :: GameDb -> Character -> [(Text, Record)]
devotionSources db c =
  [ (skName s, r)
  | s <- charSkills c
  , "/devotion/tier" `T.isInfixOf` skName s
  , not ("_skill" `T.isSuffixOf` T.dropEnd 4 (skName s))
  , Just r <- [lookupRecord (skName s) db]
  ]

-- | Always-on stat records from a character's mastery bars, resolved at the
-- invested mastery rank (they grant attributes, health, and energy by rank).
masterySources :: GameDb -> Character -> [(Text, Record)]
masterySources db c =
  [ (skName s, resolveSetTier (fromIntegral (skLevel s)) r)
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
skillSources :: BuffToggle -> [(Text, Record)] -> GameDb -> Character -> [(Text, Record)]
skillSources tog ctx db c =
  [ (skName s, resolveSetTier (effRank s) (buffStatRecord db skRec))
  | s <- charSkills c
  , skLevel s > 0
  , "records/skills/playerclass" `T.isPrefixOf` skName s
  , not ("_classtraining_" `T.isInfixOf` skName s)
  , Just skRec <- [lookupRecord (skName s) db]
  , Just cat <- [effectiveCategory skRec (skName s)]
  , allowed tog cat
  ]
  where
    effRank = rankWith (collectSkillLevels ctx)

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
        afterPenalty = gear - difficultyPenalty diff
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
  }
  deriving (Show, Eq)

statSummary :: Difficulty -> Character -> [(Text, Record)] -> StatSummary
statSummary diff c sources =
  StatSummary
    { ssResists = resistRows diff sources
    , ssAttributes =
        [ (label, (baseV + sumField sources flatField) * (1 + sumField sources pctField / 100))
        | (label, baseV, flatField, pctField) <- attrFieldsOf c
        ]
    , ssKeyTotals =
        [ row | row@(label, _, _) <- keyTotalsOf sources, label `notElem` ["Physique", "Cunning", "Spirit"]
        ]
    }

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
    sources = statSources db items ++ extra
    equipped = filter (not . emptyItemName) items
    blank xs = if null xs then [] else [""]
    penaltyNote = if difficultyPenalty diff > 0 then ": -" <> showN (difficultyPenalty diff) <> "% resist" else ""

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
    srcB = statSources db base ++ extra
    srcO = statSources db over ++ extra
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
defaultWeights :: Weights
defaultWeights = Weights {wResist = 2, wOa = 30, wDa = 80, wDamage = 1}

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

-- | Score each candidate as an overlay onto @base@, keeping net-positive results
-- best-first. Resistances use the non-linear squared-shortfall-below-@target@
-- weighting; OA/DA/damage use their deltas. @extra@ is the non-gear sources
-- (devotions, mastery, skill buffs), held constant across candidates. @slotOcc@
-- selects which equipped item of the candidate's slot type to replace (e.g. the
-- second ring), so symmetric slots can be compared independently.
findUpgrades :: Weights -> Double -> Difficulty -> Int -> Character -> [(Text, Record)] -> GameDb -> [Item] -> [(Text, Item)] -> [UpgradeRow]
findUpgrades w target diff slotOcc c extra db base candidates =
  sortOn (negate . urScore) [r | (loc, cand) <- candidates, let r = scoreOne loc cand, urScore r > 0]
  where
    srcBase = statSources db base ++ extra
    rB = resistRows diff srcBase
    kB = keyTotalsOf srcBase
    dpsB = estTotalDps srcBase
    pen x = let d = target - x in if d > 0 then d * d else 0
    flatOf l ks = case [f | (lab, f, _) <- ks, lab == l] of (x : _) -> x; [] -> 0
    -- the single number we treat as "damage": the highest active attack's DPS with
    -- every proc folded in (procs fire automatically while you attack), so the
    -- delta approximates the real change to sustained output.
    estTotalDps src =
      let rows = attackDps db src c
          actives = filter ((== Active) . adKind) rows
          best = if null actives then 0 else maximum (map adDps actives)
       in best + sum [adDps r | r <- rows, adKind r == Triggered]
    scoreOne loc cand =
      let over = overlayAt db slotOcc base cand
          srcO = statSources db over ++ extra
          rO = resistRows diff srcO
          kO = keyTotalsOf srcO
          paired = zip rB rO
          changes = [(n, b, a) | ((n, b, _, _), (_, a, _, _)) <- paired, b /= a]
          resScore = sum [pen b - pen a | ((_, b, _, _), (_, a, _, _)) <- paired]
          oaD = flatOf "Offensive Ability" kO - flatOf "Offensive Ability" kB
          daD = flatOf "Defensive Ability" kO - flatOf "Defensive Ability" kB
          dpsD = estTotalDps srcO - dpsB
          attrs = itemAttrs cand db
          sc = wResist w * resScore + wOa w * oaD + wDa w * daD + wDamage w * dpsD
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
attackDps :: GameDb -> [(Text, Record)] -> Character -> [AttackDps]
attackDps db sources c =
  sortOn (negate . adDps) actives ++ sortOn (negate . adDps) procs
  where
    actives = [r | m <- weaponRow : map compute (charSkills c), Just r <- [m]]
    procs = [r | m <- map computeWps (charSkills c) ++ itemProcs ++ devoProcs ++ onHitProcs, Just r <- [m]]
    lv = collectSkillLevels sources
    totalPct = sumField sources "offensiveTotalDamageModifier"
    aps = assumedBaseAttackSpeed * (1 + sumField sources "characterAttackSpeedModifier" / 100)
    -- conversions from gear/buffs apply to every skill
    globalConv = concatMap (recordConversions . snd) sources
    pctOf stem = sumField sources ("offensive" <> stem <> "Modifier") + totalPct
    -- total retaliation damage of a type (flat x its retaliation % modifiers)
    retalTotalOf stem =
      let (lo, hi) = sumRange sources ["retaliation"] stem
          pct = sumField sources ("retaliation" <> stem <> "Modifier") + sumField sources "retaliationTotalDamageModifier"
       in (lo + hi) / 2 * (1 + pct / 100)
    -- "% retaliation damage added to attack" from gear/buffs (applies to every skill)
    rdaGlobal = sumField sources "retaliationDamagePct"
    -- expected % cooldown reduction from a record at rank i: a flat reduction, or
    -- (reduction x chance) when it is a chance-based reset (e.g. Reprisal).
    cdrContrib i r =
      let red = maybe 0 (atRank i) (HM.lookup "skillCooldownReduction" r)
       in case HM.lookup "skillCooldownReductionChance" r of
            Just _ -> red * maybe 0 (atRank i) (HM.lookup "skillCooldownReductionChance" r) / 100
            Nothing -> red
    srcCdr = sum [cdrContrib 0 r | (_, r) <- sources]
    -- gear/buff records paired with a (scalar) rank index, for DoT/CDR aggregation
    srcRecs = [(0 :: Int, r) | (_, r) <- sources]
    aggIn recs key = sum [maybe 0 (atRank i) (HM.lookup key r) | (i, r) <- recs]
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
      [ (rankWith lv sib - 1, rr)
      | sib <- charSkills c
      , skillBase (skName sib) == skillBase (skName s)
      , skLevel sib > 0
      , Just rr <- [lookupRecord (skName sib) db]
      , skName sib == skName s || not (isPrimary rr)
      ]
    emit s =
      let sibs = sibsOf s
       in mkRow (skillDisplayName db (skName s)) (Just (rankWith lv s)) (aggIn sibs "weaponDamagePct") (aggIn sibs "skillCooldownTime") sibs
    -- a WPS row: weapon-scaled per-hit like an attack, but contributing only on
    -- the @chance@ fraction of swings it replaces, so it adds to your spammed
    -- attack rather than being an alternative to it.
    emitWps s r =
      let sibs = sibsOf s
          rank = rankWith lv s
          chance = maybe 0 (atRank (rank - 1)) (HM.lookup "skillChanceWeight" r) / 100
          typed = typedDamage (aggIn sibs "weaponDamagePct") sibs
          perHit = sum (map snd typed)
          rate = showInt (chance * 100) <> "% WPS on attack"
       in if perHit <= 0 || chance <= 0
            then Nothing
            else Just (AttackDps (skillDisplayName db (skName s)) (Just rank) Triggered perHit (perHit * chance * aps) rate typed)
    -- the bare auto-attack: 100% weapon damage, no skill, spammed at attack speed
    weaponRow = mkRow "Weapon Attack" Nothing 100 0 []
    -- The per-type per-application damage for a group of contributing records
    -- @sibs@ (rank-indexed), with weapon damage scaling @wpnPct@: weapon flat (from
    -- gear in @sources@) + retaliation-added, x weapon%, plus the records' own flat;
    -- conversions; then % damage modifiers. Plus the stacking-DoT term. The weapon
    -- attack and skills pass @wpnPct@/@sibs@; procs pass @wpnPct = 0@ and the single
    -- proc record (its damage is flat, not weapon-scaled).
    typedDamage wpnPct sibs =
      let dotRecs = srcRecs ++ sibs
          rdaPct = rdaGlobal + sum [maybe 0 (atRank i) (HM.lookup "retaliationDamagePct" rr) | (i, rr) <- sibs]
          sflat stem =
            sum
              [ (maybe 0 (atRank i) (HM.lookup ("offensive" <> stem <> "Min") rr) + maybe 0 (atRank i) (HM.lookup ("offensive" <> stem <> "Max") rr)) / 2
              | (i, rr) <- sibs
              ]
          flatOf stem =
            let (lo, hi) = sumRange sources ["offensive", "offensiveBase", "offensiveBonus"] stem
                wflat = (lo + hi) / 2
                rdaFlat = retalTotalOf stem * rdaPct / 100
             in (wflat + rdaFlat) * wpnPct / 100 + sflat stem
          flat0 = HM.fromList [(stem, flatOf stem) | (stem, _) <- damageElems]
          skillConv = concatMap (recordConversions . snd) sibs
          flat = applyConversions (globalConv ++ skillConv) flat0
          immediate =
            [ (effectDisplay ["offensive"] tok, v)
            | (stem, tok) <- damageElems
            , let v = HM.lookupDefault 0 stem flat * (1 + pctOf stem / 100)
            , v >= 1
            ]
          dotRaw stem =
            let perRec (i, r) =
                  (maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Min") r) + maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Max") r)) / 2
                    * maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "DurationMin") r)
                gearDot = sum (map perRec srcRecs)
                skillDot = sum (map perRec sibs)
             in gearDot * wpnPct / 100 + skillDot
          dotConv = applyConversions (globalConv ++ skillConv) (HM.fromList [(stem, dotRaw stem) | (stem, _) <- dotElems])
          dotMods stem =
            (1 + aggIn dotRecs ("offensiveSlow" <> stem <> "DurationModifier") / 100)
              * (1 + (aggIn dotRecs ("offensiveSlow" <> stem <> "Modifier") + totalPct) / 100)
          dot =
            [ (effectDisplay ["offensive", "slow"] tok <> " (dot)", v)
            | (stem, tok) <- dotElems
            , let v = HM.lookupDefault 0 stem dotConv * dotMods stem
            , v >= 1
            ]
       in immediate ++ dot
    -- an actively-used attack (skill group or weapon attack): spam at attack speed
    -- (weapon%) or once per cooldown.
    mkRow name mRank wpnPct cdBase sibs =
      let cdr = srcCdr + sum [cdrContrib i rr | (i, rr) <- sibs]
          cd = max 0.1 (cdBase * (1 - cdr / 100)) -- floored so heavy CDR can't blow up the rate
          typed = typedDamage wpnPct sibs
          perHit = sum (map snd typed)
          (dps, rate)
            | cdBase > 0 = (perHit / cd, oneDp cd <> "s cooldown")
            | wpnPct > 0 = (perHit * aps, "~" <> oneDp aps <> "/s attacks (assumed base)")
            | otherwise = (0, "")
       in if perHit <= 0 || T.null rate
            then Nothing
            else Just (AttackDps name mRank Active perHit dps rate typed)
    -- a proc: fires automatically on attack/hit at chance @p@, no more than once
    -- per cooldown. Expected interval = cooldown + the geometric wait for the next
    -- successful roll (@1 / (p x attacks-per-second)@). Damage is flat (no weapon
    -- scaling). @rank@ is the granted/invested level used to index value arrays.
    mkProc name rank rec p cd trig =
      let typed = typedDamage 0 [(rank - 1, rec)]
          perHit = sum (map snd typed)
          interval = cd + 1 / max 0.01 (p * aps)
          rate = showInt (p * 100) <> "% on " <> trig <> ", " <> oneDp cd <> "s cd"
       in if perHit <= 0 then Nothing else Just (AttackDps name Nothing Triggered perHit (perHit / interval) rate typed)
    showInt x = T.pack (show (round x :: Integer))
    levelOf v = maybe 1 id (v >>= valueText >>= (readMaybe . T.unpack))
    -- procs granted by equipped items (itemSkillName + a cast_@... controller)
    itemProcs =
      [ mkProc (skillDisplayName db skn) rank rec p cd trig
      | (skn, ir) <- nubBy (\a b -> fst a == fst b) [(s, ir) | (_, ir) <- sources, Just s <- [lookupField "itemSkillName" ir >>= valueText]]
      , Just rec <- [lookupRecord skn db]
      , Just (trig, p) <- [lookupField "itemSkillAutoController" ir >>= valueText >>= parseProcController]
      , let rank = levelOf (lookupField "itemSkillLevelEq" ir)
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
    -- procs bound to invested devotion stars (templateAutoCast controller)
    devoProcs =
      [ mkProc (skillDisplayName db (skName s)) rank rec p cd trig
      | s <- charSkills c
      , "skills/devotion" `T.isInfixOf` skName s
      , skLevel s > 0
      , Just rec <- [lookupRecord (skName s) db]
      , Just (trig, p) <- [lookupField "templateAutoCast" rec >>= valueText >>= parseProcController]
      , let rank = rankWith lv s
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
    -- learned skills that fire on hit (Skill_OnHit*), e.g. Vindictive Flame
    onHitProcs =
      [ mkProc (skillDisplayName db (skName s)) rank rec p cd "hit"
      | s <- charSkills c
      , "records/skills/playerclass" `T.isPrefixOf` skName s
      , skLevel s > 0
      , Just rec <- [lookupRecord (skName s) db]
      , isOnHit rec
      , let rank = rankWith lv s
      , let p = maybe 1 (/ 100) (recNum rec "onHitActivationChance")
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]

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
