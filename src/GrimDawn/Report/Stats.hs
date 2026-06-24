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
  , renderStats
  , renderStatsDiff
    -- * Upgrade search
  , Weights (..)
  , defaultWeights
  , setWeight
  , UpgradeRow (..)
  , findUpgrades
  , renderUpgrades
    -- * Attack DPS estimate
  , assumedBaseAttackSpeed
  , AttackDps (..)
  , attackDps
  , renderDps
  ) where

import Data.Char (isDigit, isLower, toLower)
import qualified Data.HashMap.Strict as HM
import Data.List (nub, sortOn)
import Data.Maybe (listToMaybe)
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
        (before, _old : after) -> before ++ cand : after
        (before, []) -> before ++ [cand]
    slotType it = iaType (itemAttrs it db)

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
    attrFields =
      [ ("Physique", charPhysique c, "characterStrength", "characterStrengthModifier")
      , ("Cunning", charCunning c, "characterDexterity", "characterDexterityModifier")
      , ("Spirit", charSpirit c, "characterIntelligence", "characterIntelligenceModifier")
      ]

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
-- squared-shortfall in the thousands; OA/DA/damage deltas are tens to hundreds).
defaultWeights :: Weights
defaultWeights = Weights {wResist = 1, wOa = 50, wDa = 50, wDamage = 25}

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
  , urLevel :: !(Maybe Int)
  , urResists :: ![(Text, Double, Double)] -- (type, before, after), changed only
  , urOa :: !Double
  , urDa :: !Double
  , urDamage :: !Double
  }
  deriving (Show, Eq)

-- | Score each candidate as an overlay onto @base@, keeping net-positive results
-- best-first. Resistances use the non-linear squared-shortfall-below-@target@
-- weighting; OA/DA/damage use their deltas. @extra@ is the non-gear sources
-- (devotions, mastery, skill buffs), held constant across candidates.
findUpgrades :: Weights -> Double -> Difficulty -> [(Text, Record)] -> GameDb -> [Item] -> [Item] -> [UpgradeRow]
findUpgrades w target diff extra db base candidates =
  sortOn (negate . urScore) [r | cand <- candidates, let r = scoreOne cand, urScore r > 0]
  where
    srcBase = statSources db base ++ extra
    rB = resistRows diff srcBase
    kB = keyTotalsOf srcBase
    dmgB = damageScore srcBase
    pen x = let d = target - x in if d > 0 then d * d else 0
    flatOf l ks = case [f | (lab, f, _) <- ks, lab == l] of (x : _) -> x; [] -> 0
    scoreOne cand =
      let over = overlay db base [cand]
          srcO = statSources db over ++ extra
          rO = resistRows diff srcO
          kO = keyTotalsOf srcO
          paired = zip rB rO
          changes = [(n, b, a) | ((n, b, _, _), (_, a, _, _)) <- paired, b /= a]
          resScore = sum [pen b - pen a | ((_, b, _, _), (_, a, _, _)) <- paired]
          oaD = flatOf "Offensive Ability" kO - flatOf "Offensive Ability" kB
          daD = flatOf "Defensive Ability" kO - flatOf "Defensive Ability" kB
          dmgD = damageScore srcO - dmgB
          attrs = itemAttrs cand db
          sc = wResist w * resScore + wOa w * oaD + wDa w * daD + wDamage w * dmgD
       in UpgradeRow sc (iaDisplayName attrs) (iaLevelRequirement attrs) changes oaD daD dmgD

-- | Render the ranked upgrade rows. Resist changes are coloured by type when
-- @useColor@ is set.
renderUpgrades :: Bool -> [UpgradeRow] -> Text
renderUpgrades useColor = T.unlines . concatMap fmtRow
  where
    fmtRow r =
      [ "  " <> rpad 7 (showScore (urScore r)) <> "  lvl " <> rpad 3 (lvl r) <> "  " <> urName r
      , T.replicate 13 " " <> body r
      ]
    lvl r = maybe "-" (T.pack . show) (urLevel r)
    body r =
      T.intercalate "; " (map (colorByType useColor . resseg) (urResists r)) <> off r
    resseg (n, b, a) = n <> " " <> showN b <> "% -> " <> showN a <> "% (" <> sign (a - b) <> ")"
    off r =
      let parts =
            ["OA " <> sign (urOa r) | urOa r /= 0]
              ++ ["DA " <> sign (urDa r) | urDa r /= 0]
              ++ ["dmg " <> sign (urDamage r) | urDamage r /= 0]
       in if null parts then "" else (if null (urResists r) then "" else "  ") <> "[" <> T.intercalate ", " parts <> "]"
    showScore x = T.pack (show (round x :: Integer))

--------------------------------------------------------------------------------
-- Attack DPS estimate
--------------------------------------------------------------------------------

-- | Assumed base weapon attack rate (attacks/sec) for spam attacks, since the
-- real per-weapon base speed lives in game data not in the extracted DB. Refine
-- when that data is available.
assumedBaseAttackSpeed :: Double
assumedBaseAttackSpeed = 1.0

data AttackDps = AttackDps
  { adName :: !Text
  , adRank :: !(Maybe Int) -- Nothing for the bare weapon attack
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
-- No crit, enemy resistances, or other chance procs.
attackDps :: GameDb -> [(Text, Record)] -> Character -> [AttackDps]
attackDps db sources c =
  sortOn (negate . adDps) [r | m <- weaponRow : map compute (charSkills c), Just r <- [m]]
  where
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
    compute s
      | not ("records/skills/playerclass" `T.isPrefixOf` skName s) = Nothing
      | skLevel s <= 0 = Nothing
      | otherwise = case lookupRecord (skName s) db of
          Just r | isPrimary r -> emit s
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
    -- the bare auto-attack: 100% weapon damage, no skill, spammed at attack speed
    weaponRow = mkRow "Weapon Attack" Nothing 100 0 []
    -- core per-application damage + DPS for a skill group (sibs) or the weapon
    -- attack (sibs = []), given the group's aggregate weapon% and base cooldown.
    mkRow name mRank wpnPct cdBase sibs =
      let dotRecs = srcRecs ++ sibs -- gear + this skill group, for DoT
          cdr = srcCdr + sum [cdrContrib i rr | (i, rr) <- sibs]
          -- effective cooldown (floored so heavy CDR can't blow up the rate)
          cd = max 0.1 (cdBase * (1 - cdr / 100))
          rdaPct = rdaGlobal + sum [maybe 0 (atRank i) (HM.lookup "retaliationDamagePct" rr) | (i, rr) <- sibs]
          -- the group's own flat (immediate) damage per type, incl. secondaries
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
          -- damage-over-time per application: (per-second x duration) over gear +
          -- this skill group. Since DoTs stack, this per-application total x the
          -- attack rate is its sustained DPS contribution. Conversions apply to
          -- the DoT too (e.g. Fire->Acid converts Burn to the Poison DoT), so the
          -- raw totals are converted before the destination type's DoT modifiers.
          dotRaw stem =
            let perRec (i, r) =
                  (maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Min") r) + maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Max") r)) / 2
                    * maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "DurationMin") r)
                gearDot = sum (map perRec srcRecs) -- weapon-scaled (like flat gear damage)
                skillDot = sum (map perRec sibs) -- the skill's own DoT
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
          typed = immediate ++ dot
          perHit = sum (map snd typed)
          (dps, rate)
            | cdBase > 0 = (perHit / cd, oneDp cd <> "s cooldown")
            | wpnPct > 0 = (perHit * aps, "~" <> oneDp aps <> "/s attacks (assumed base)")
            | otherwise = (0, "")
       in if perHit <= 0 || T.null rate
            then Nothing
            else Just (AttackDps name mRank perHit dps rate typed)

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
renderDps :: Bool -> [AttackDps] -> Text
renderDps useColor = T.unlines . concatMap fmt
  where
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
