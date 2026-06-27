-- | Item interpretation: turn a parsed save 'Item' plus the game database into
-- a display name, set membership, and the record-level attributes the @items@
-- report filters on. Port of the relevant parts of gd-edit's @db_utils.clj@
-- (@item-name@, @related-db-records@, @item-base-record-get-name@) and the
-- field names used in @item_summary.clj@, confirmed against the real database.
module GrimDawn.Item
  ( ItemAttrs (..)
  , relatedRecordNames
  , relatedRecords
  , baseRecord
  , itemDisplayName
  , isSetItem
  , setRecordName
  , itemAttrs
  , skillDisplayName
    -- * Bonus extractors (re-used for set bonuses)
  , resistBonuses
  , damageBonuses
  , characterBonuses
  , skillBonuses
    -- * Aggregation helpers (re-used by stat totals)
  , sumField
  , sumRange
  , resistFieldMap
  , effectName
  , effectDisplay
  , damageElems
  , dotElems
  , resolveSetTier
    -- * Attribute vocabularies
  , resistTypes
  , damageTypes
  ) where

import Data.Char (isUpper)
import qualified Data.HashMap.Strict as HM
import Data.List (find, nub, sortOn)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Arz (Record, Value (..), lookupField, valueInt, valueText)
import GrimDawn.Db (GameDb, lookupRecord)
import GrimDawn.Gdc (Item (..))

-- | Record-level attributes a single owned item exposes for filtering.
data ItemAttrs = ItemAttrs
  { iaDisplayName :: !Text
  , iaClass :: !(Maybe Text) -- raw base "Class", e.g. "ArmorProtective_Head"
  , iaType :: !(Maybe Text) -- lowercased subtype, e.g. "head", "sword", "ring"
  , iaClassification :: !(Maybe Text) -- Common/Magical/Rare/Epic/Legendary
  , iaLevelRequirement :: !(Maybe Int)
  , iaResists :: !(Set Text) -- resistance types present (fire, cold, ...)
  , iaResistBonuses :: ![Text] -- rendered resistance amounts, e.g. "45% Fire"
  , iaDamage :: !(Set Text) -- offensive damage types present
  , iaDamageBonuses :: ![Text] -- rendered damage bonuses, e.g. "+12-18 Fire", "32% Pierce"
  , iaBonuses :: ![Text] -- other stat bonuses, e.g. "+450 Armor", "+8% Experience Gained"
  , iaSkillBonuses :: ![Text] -- rendered skill bonuses, e.g. "+1 to all Skills", "Grants Ring of Steel"
  , iaIsSet :: !Bool
  , iaSetRecord :: !(Maybe Text)
  , iaBitmap :: !(Maybe Text) -- texture path inside the asset archive, e.g.
  -- "items/gearhead/bitmaps/d115_head.tex"
  }
  deriving (Show, Eq)

--------------------------------------------------------------------------------
-- Related records / naming
--------------------------------------------------------------------------------

-- | The record-name fields an item references (basename, affixes, relic,
-- augment), keeping only non-empty @records/@ paths.
relatedRecordNames :: Item -> [Text]
relatedRecordNames it =
  filter (T.isPrefixOf "records/")
    [ itemBaseName it
    , itemPrefixName it
    , itemSuffixName it
    , itemModifierName it
    , itemTransmuteName it
    , itemRelicName it
    , itemRelicBonus it
    , itemAugmentName it
    ]

-- | The referenced records that exist in the database, paired with their name.
relatedRecords :: Item -> GameDb -> [(Text, Record)]
relatedRecords it db =
  [ (n, r) | n <- relatedRecordNames it, Just r <- [lookupRecord n db] ]

baseRecord :: Item -> GameDb -> Maybe Record
baseRecord it = lookupRecord (itemBaseName it)

textField :: Text -> Record -> Maybe Text
textField f r = lookupField f r >>= valueText

-- base display name: itemNameTag, else description with "^k" stripped.
baseName :: Record -> Maybe Text
baseName r =
  textField "itemNameTag" r
    `orElse` (T.replace "^k" "" <$> textField "description" r)

qualityName :: Record -> Maybe Text
qualityName r = textField "itemQualityTag" r `orElse` textField "itemStyleTag" r

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y

-- | The first 'Just' in a list, or 'Nothing'.
firstJust :: [Maybe a] -> Maybe a
firstJust = foldr orElse Nothing

-- | True when any related record carries an @itemSetName@ field.
isSetItem :: Item -> GameDb -> Bool
isSetItem it db = any (HM.member "itemSetName" . snd) (relatedRecords it db)

-- | The set definition record name this item belongs to, if any.
setRecordName :: Item -> GameDb -> Maybe Text
setRecordName it db =
  case mapMaybe (textField "itemSetName" . snd) (relatedRecords it db) of
    (s : _) -> Just s
    [] -> Nothing

-- | Construct the item's display name, mirroring gd-edit's @item-name@:
-- set items use quality + base only; others use prefix + quality + base + suffix.
itemDisplayName :: Item -> GameDb -> Maybe Text
itemDisplayName it db = do
  let related = relatedRecords it db
  base <- baseRecord it db
  bn <- baseName base
  let setItem = any (HM.member "itemSetName" . snd) related
      affixName needle =
        textField "lootRandomizerName" . snd
          =<< find (\(n, _) -> needle `T.isInfixOf` n) related
  pure $
    if setItem
      then joinParts [qualityName base, Just bn]
      else
        joinParts
          [ affixName "/prefix/"
          , qualityName base
          , Just bn
          , affixName "/suffix/"
          ]

joinParts :: [Maybe Text] -> Text
joinParts = T.unwords . filter (not . T.null) . map (fromMaybe "")

--------------------------------------------------------------------------------
-- Filter attributes
--------------------------------------------------------------------------------

-- | The resistance types and the DB fields that indicate them. Elemental fields
-- count toward fire/cold/lightning.
resistFieldMap :: [(Text, [Text])]
resistFieldMap =
  [ ("fire", ["defensiveFire", "defensiveElementalResistance"])
  , ("cold", ["defensiveCold", "defensiveElementalResistance"])
  , ("lightning", ["defensiveLightning", "defensiveElementalResistance"])
  , ("poison", ["defensivePoison"])
  , ("aether", ["defensiveAether"])
  , ("chaos", ["defensiveChaos"])
  , ("vitality", ["defensiveLife"])
  , ("pierce", ["defensivePierce"])
  , ("bleed", ["defensiveBleeding"])
  , ("physical", ["defensivePhysical"])
  ]

-- | Damage types and their GD field stems (we check offensive[Base]<Stem>Min/Max).
damageFieldMap :: [(Text, [Text])]
damageFieldMap =
  [ ("physical", ["Physical"])
  , ("fire", ["Fire"])
  , ("cold", ["Cold"])
  , ("lightning", ["Lightning"])
  , ("poison", ["Poison"])
  , ("aether", ["Aether"])
  , ("chaos", ["Chaos"])
  , ("vitality", ["Life"])
  , ("pierce", ["Pierce"])
  , ("bleed", ["Bleeding"])
  , ("elemental", ["Elemental"])
  ]

-- | Rendered resistance amounts across the item's records, e.g. "45% Fire".
-- Elemental resistance is folded into each of fire/cold/lightning. Names use the
-- defensive context (so poison resistance reads "Poison & Acid").
resistBonuses :: [(Text, Record)] -> [Text]
resistBonuses related =
  [ showNum v <> "% " <> resistName ty
  | (ty, fields) <- resistFieldMap
  , let v = sum (map (sumField related) fields)
  , v > 0
  ]
  where
    resistName ty = effectDisplay ["defensive"] (resistToken ty)
    -- map resist keys to gd-edit component tokens
    resistToken "vitality" = "life"
    resistToken "bleed" = "bleeding"
    resistToken t = t

capitalize :: Text -> Text
capitalize t = T.toUpper (T.take 1 t) <> T.drop 1 t

resistTypes :: [Text]
resistTypes = map fst resistFieldMap

damageTypes :: [Text]
damageTypes = map fst damageFieldMap

-- subtype: lowercased substring of "Class" after the last underscore.
classSubtype :: Text -> Maybe Text
classSubtype cls =
  case T.splitOn "_" cls of
    [] -> Nothing
    parts -> let s = last parts in if T.null s then Nothing else Just (T.toLower s)

anyFieldPresent :: [(Text, Record)] -> [Text] -> Bool
anyFieldPresent related fields =
  any (\(_, r) -> any (`HM.member` r) fields) related

damagePresent :: [(Text, Record)] -> [Text] -> Bool
damagePresent related stems =
  anyFieldPresent related
    [ prefix <> s <> suf
    | s <- stems
    , suf <- ["Min", "Max"]
    , prefix <- ["offensive", "offensiveBase"]
    ]

--------------------------------------------------------------------------------
-- Damage bonuses (flat + / percent %)
--------------------------------------------------------------------------------

-- | Damage/resistance display names by component, ported from gd-edit's
-- @effect-types@ / @effect-components@. The crucial GD quirk: the bare element
-- field (e.g. @offensivePoison@) is the *immediate* damage ("Acid"), while the
-- @Slow@ variant (@offensiveSlowPoison@) is the *damage-over-time* ("Poison").
-- Likewise Fire/Burn, Cold/Frostburn, Lightning/Electrocute, Physical/Internal
-- Trauma, Vitality/Vitality Decay.
effectComponents :: [(Text, [Text])]
effectComponents =
  [ ("Poison & Acid", ["defensive", "poison"])
  , ("Internal Trauma", ["slow", "physical"])
  , ("Burn", ["slow", "fire"])
  , ("Frostburn", ["slow", "cold"])
  , ("Electrocute", ["slow", "lightning"])
  , ("Poison", ["slow", "poison"])
  , ("Vitality Decay", ["slow", "life"])
  , ("Physical", ["physical"])
  , ("Fire", ["fire"])
  , ("Cold", ["cold"])
  , ("Lightning", ["lightning"])
  , ("Acid", ["poison"])
  , ("Vitality", ["life"])
  , ("Pierce", ["pierce"])
  , ("Bleeding", ["bleeding"])
  , ("Aether", ["aether"])
  , ("Chaos", ["chaos"])
  , ("Elemental", ["elemental"])
  ]

-- | The display name for a set of components (gd-edit's @effect-by-components@):
-- the entry whose required components are all present wins, longest set first
-- (so DoT/resistance variants beat the bare element).
effectName :: [Text] -> Maybe Text
effectName comps = fst <$> find (\(_, req) -> all (`elem` comps) req) ordered
  where
    ordered = sortOn (negate . length . snd) effectComponents

-- | Display name for an element in a context (e.g. @["offensive"]@,
-- @["offensive","slow"]@, @["retaliation"]@), falling back to the capitalised
-- token if unrecognised.
effectDisplay :: [Text] -> Text -> Text
effectDisplay ctx token = fromMaybe (capitalize token) (effectName (ctx ++ [token]))

-- field stem (as in @offensive<Stem>Min@) paired with its component token.
damageElems :: [(Text, Text)]
damageElems =
  [ ("Physical", "physical"), ("Fire", "fire"), ("Cold", "cold"), ("Lightning", "lightning")
  , ("Poison", "poison"), ("Life", "life"), ("Pierce", "pierce"), ("Bleeding", "bleeding")
  , ("Aether", "aether"), ("Chaos", "chaos")
  ]

-- stems that also have a damage-over-time (@offensiveSlow<Stem>@) variant.
dotElems :: [(Text, Text)]
dotElems =
  [ ("Physical", "physical"), ("Fire", "fire"), ("Cold", "cold")
  , ("Lightning", "lightning"), ("Poison", "poison"), ("Life", "life")
  ]

-- numeric (scalar) value of a field
fieldNum :: Text -> Record -> Maybe Double
fieldNum f r = case lookupField f r of
  Just (VInt i) -> Just (fromIntegral i)
  Just (VFloat x) -> Just (realToFrac x)
  _ -> Nothing

-- sum a scalar field across all related records
sumField :: [(Text, Record)] -> Text -> Double
sumField related f = sum [v | (_, r) <- related, Just v <- [fieldNum f r]]

-- | Summed (min, max) for a damage stem across records, over the given field
-- prefixes (e.g. @offensive@, @offensiveBase@, @offensiveBonus@). A source that
-- supplies only a Min or only a Max (a flat amount) is treated as min == max, so
-- the totals can never invert into a "173-101" range.
sumRange :: [(Text, Record)] -> [Text] -> Text -> (Double, Double)
sumRange related prefixes stem = (sum (map fst pairs), sum (map snd pairs))
  where
    pairs =
      [ (fromMaybe (fromMaybe 0 mx) mn, fromMaybe (fromMaybe 0 mn) mx)
      | (_, r) <- related
      , p <- prefixes
      , let mn = fieldNum (p <> stem <> "Min") r
            mx = fieldNum (p <> stem <> "Max") r
      , isJust mn || isJust mx
      ]

-- | Collapse a set record's array bonus fields to the value for the given
-- equipped-piece count (set arrays are indexed by pieces-1; scalars and string
-- fields pass through unchanged).
resolveSetTier :: Int -> Record -> Record
resolveSetTier cnt = HM.map pick
  where
    idx = max 0 (cnt - 1)
    pick (VList xs) | not (null xs) = xs !! min idx (length xs - 1)
    pick v = v

-- render a damage range, collapsing to a single number when min == max.
showRange :: Double -> Double -> Text
showRange lo hi = if lo > 0 && lo /= hi then showNum lo <> "-" <> showNum hi else showNum hi

-- show a whole number without a trailing ".0", otherwise round to 1 decimal
-- (avoids float artifacts like 4.100000023841858).
showNum :: Double -> Text
showNum x =
  let r = round x :: Integer
   in if fromIntegral r == x
        then T.pack (show r)
        else T.pack (show (fromIntegral (round (x * 10) :: Integer) / 10 :: Double))

-- | Rendered damage bonuses across the item's records: immediate flat then
-- damage-over-time (with its duration) then percent modifiers. Immediate and DoT
-- damage are named per gd-edit (e.g. Acid vs Poison, Fire vs Burn).
damageBonuses :: [(Text, Record)] -> [Text]
damageBonuses related =
  immFlat ++ dotFlat ++ immPct ++ dotPct ++ dotDuration
  where
    -- immediate flat damage, e.g. "+12-18 Fire", "+8-15 Acid"
    immFlat =
      [ "+" <> showRange lo hi <> " " <> effectDisplay ["offensive"] tok
      | (stem, tok) <- damageElems
      , let (lo, hi) = sumRange related ["offensive", "offensiveBase", "offensiveBonus"] stem
      , hi > 0
      ]
    -- damage-over-time: per-second value x duration, e.g. "+30 Burn over 3s"
    dotFlat =
      [ "+" <> showRange (lo * mult) (hi * mult) <> " " <> effectDisplay ["offensive", "slow"] tok
          <> (if dur > 0 then " over " <> showNum dur <> "s" else "")
      | (stem, tok) <- dotElems
      , let (lo, hi) = sumRange related ["offensiveSlow"] stem
      , hi > 0
      , let dur = sumField related ("offensiveSlow" <> stem <> "DurationMin")
      , let mult = if dur > 0 then dur else 1
      ]
    -- % immediate damage, e.g. "50% Acid", plus the Elemental aggregate
    immPct =
      [ showNum p <> "% " <> effectDisplay ["offensive"] tok
      | (stem, tok) <- damageElems ++ [("Elemental", "elemental")]
      , let p = sumField related ("offensive" <> stem <> "Modifier")
      , p > 0
      ]
    -- % damage-over-time, e.g. "44% Burn"
    dotPct =
      [ showNum p <> "% " <> effectDisplay ["offensive", "slow"] tok
      | (stem, tok) <- dotElems
      , let p = sumField related ("offensiveSlow" <> stem <> "Modifier")
      , p > 0
      ]
    -- % increased damage-over-time duration, e.g. "+20% Burn Duration"
    dotDuration =
      [ "+" <> showNum p <> "% " <> effectDisplay ["offensive", "slow"] tok <> " Duration"
      | (stem, tok) <- dotElems
      , let p = sumField related ("offensiveSlow" <> stem <> "DurationModifier")
      , p > 0
      ]

--------------------------------------------------------------------------------
-- Character / defensive / utility bonuses
--------------------------------------------------------------------------------

-- | Value-formatting options, mirroring gd-edit's @val->string-@.
data Opt = Signed | Percentage | Negative deriving (Eq)

-- | Explicit field -> (format-template, options) table, ported from gd-edit's
-- @effect-string-map@ (item_summary.clj). The template contains a single @%s@
-- placeholder for the formatted value. Fields handled by the damage, resist, or
-- skill renderers are filtered out before this is consulted (see 'engineExcluded').
effectStringMap :: [(Text, (Text, [Opt]))]
effectStringMap =
  [ ("characterAttackSpeedModifier", ("%s Attack Speed", [Signed, Percentage]))
  , ("characterConstitutionModifier", ("%s Constitution", [Percentage]))
  , ("characterDefensiveAbility", ("%s Defensive Ability", [Signed]))
  , ("characterDefensiveAbilityModifier", ("%s Defensive Ability", [Signed, Percentage]))
  , ("characterDeflectProjectile", ("%s Chance to Avoid Projectiles", [Percentage]))
  , ("characterDodgePercent", ("%s Chance to Avoid Melee Attacks", [Percentage]))
  , ("characterDexterity", ("%s Cunning", [Signed]))
  , ("characterDexterityModifier", ("%s Cunning", [Signed, Percentage]))
  , ("characterEnergyAbsorptionPercent", ("%s Energy Absorbed from Enemy Spells", [Signed, Percentage]))
  , ("characterGlobalReqReduction", ("%s to all Requirements", [Percentage, Negative]))
  , ("characterHuntingDexterityReqReduction", ("%s Cunning Requirement for Ranged Weapons", [Percentage, Negative]))
  , ("characterHealIncreasePercent", ("%s Increased Healing", [Signed, Percentage]))
  , ("characterIncreasedExperience", ("%s Experience Gained", [Signed, Percentage]))
  , ("characterIntelligence", ("%s Spirit", [Signed]))
  , ("characterIntelligenceModifier", ("%s Spirit", [Signed, Percentage]))
  , ("characterLife", ("%s Health", [Signed]))
  , ("characterLifeModifier", ("%s Health", [Signed, Percentage]))
  , ("characterLifeRegen", ("%s Health Regenerated per second", [Signed]))
  , ("characterLifeRegenModifier", ("Increases Health Regeneration by %s", [Percentage]))
  , ("characterMana", ("%s Energy", [Signed]))
  , ("characterManaModifier", ("%s Energy", [Signed, Percentage]))
  , ("characterManaRegen", ("%s Energy Regenerated per second", [Signed]))
  , ("characterManaRegenModifier", ("Increases Energy Regeneration by %s", [Percentage]))
  , ("characterManaLimitReserve", ("%s Energy Reserved", []))
  , ("characterOffensiveAbility", ("%s Offensive Ability", [Signed]))
  , ("characterOffensiveAbilityModifier", ("%s Offensive Ability", [Signed, Percentage]))
  , ("characterRunSpeedModifier", ("%s Movement Speed", [Signed, Percentage]))
  , ("characterSpellCastSpeedModifier", ("%s Casting Speed", [Signed, Percentage]))
  , ("characterStrength", ("%s Physique", [Signed]))
  , ("characterStrengthModifier", ("%s Physique", [Signed, Percentage]))
  , ("characterTotalSpeedModifier", ("%s Total Speed", [Signed, Percentage]))
  , ("damageAbsorptionPercent", ("%s Damage Absorption", [Percentage]))
  , ("damageAbsorptionReflectPercent", ("%s Damage Absorbed Reflected", [Percentage]))
  , ("defensiveAbsorptionModifier", ("%s Armor Absorption", [Signed, Percentage]))
  , ("defensiveBleedingDuration", ("%s Reduction in Bleeding Duration", [Percentage]))
  , ("defensiveBlock", ("%s Damage Blocked", [Signed]))
  , ("defensiveBlockAmountModifier", ("%s Shield Damage Blocked", [Signed, Percentage]))
  , ("defensiveBlockChance", ("%s Shield Block Chance", [Signed, Percentage]))
  , ("defensiveBlockModifier", ("%s Shield Block Chance", [Signed, Percentage]))
  , ("defensiveAllMaxResist", ("%s to All Maximum Resistances", [Signed, Percentage]))
  , ("characterDefensiveBlockRecoveryReduction", ("%s Shield Recovery", [Signed, Percentage, Negative]))
  , ("defensiveDisruption", ("%s Skill Disruption Resistance", [Percentage]))
  , ("defensiveFreeze", ("%s Reduced Freeze Duration", [Percentage]))
  , ("defensivePercentCurrentLife", ("%s Resistance to Life Reduction", [Percentage]))
  , ("defensivePercentReflectionResistance", ("%s Reflected Damage Reduction", [Percentage]))
  , ("defensivePetrify", ("%s Reduced Petrify Duration", [Percentage]))
  , ("defensiveProtectionModifier", ("Increases Armor by %s", [Percentage]))
  , ("defensiveSleep", ("%s Sleep Resistance", [Percentage]))
  , ("defensiveStun", ("%s Reduced Stun Duration", [Percentage]))
  , ("defensiveTotalSpeedResistance", ("%s Slow Resistance", [Percentage]))
  , ("defensiveTrap", ("%s Reduced Entrapment Duration", [Percentage]))
  , ("offensiveCritDamageModifier", ("%s Crit Damage", [Signed, Percentage]))
  , ("offensiveLifeLeechMin", ("%s of Attack Damage converted to Health", [Percentage]))
  , ("offensivePierceRatioMin", ("%s Armor Piercing", [Percentage]))
  , ("offensiveTotalDamageModifier", ("%s to All Damage", [Signed, Percentage]))
  , ("retaliationDamagePct", ("%s of Retaliation Damage added to Attack", [Percentage]))
  , ("retaliationTotalDamageModifier", ("%s to All Retaliation Damage", [Signed, Percentage]))
  , ("skillCooldownReduction", ("%s Skill Cooldown Reduction", [Signed, Percentage]))
  , ("skillManaCost", ("%s Energy Cost", []))
  , ("skillManaCostReduction", ("%s Skill Energy Cost", [Signed, Percentage, Negative]))
  , ("weaponDamagePct", ("%s Weapon Damage", [Percentage]))
  ]

-- | Fields gd-edit ignores outright.
effectIgnoreFields :: [Text]
effectIgnoreFields = ["skillChargeAura", "skillChargeMultipliers"]

-- format a single value into the template's @%s@ slot, applying the options.
formatEffect :: Text -> [Opt] -> Double -> Text
formatEffect tmpl opts v = T.replace "%s" valStr tmpl
  where
    v' = if Negative `elem` opts then negate v else v
    signed = if Signed `elem` opts && v' > 0 then "+" <> showNum v' else showNum v'
    valStr = if Percentage `elem` opts then signed <> "%" else signed

-- show a value with an explicit leading sign for positives.
showSigned :: Double -> Text
showSigned x = if x > 0 then "+" <> showNum x else showNum x

-- split a camelCase field name into lowercased component words.
splitCamel :: Text -> [Text]
splitCamel = map T.toLower . T.split (== ' ') . T.concatMap spaceUpper
  where
    spaceUpper c = if isUpper c then T.pack [' ', c] else T.singleton c

-- | Rendered bonus lines: gd-edit's @effect-string-map@ for known fields, plus a
-- camelCase-component fallback so anything unmapped still shows. Damage, resists,
-- per-type retaliation, and skills are rendered by their own functions and
-- excluded here. Each field is summed across the item's related records.
characterBonuses :: [(Text, Record)] -> [Text]
characterBonuses related =
  armor ++ retaliation ++ dedupe (map snd (sortOn fst (concatMap render fieldsU)))
  where
    fieldsU = nub [k | (_, r) <- related, k <- HM.keys r]

    armor =
      let a = sumField related "defensiveProtection" + sumField related "defensiveBonusProtection"
       in [showSigned a <> " Armor" | a /= 0]
    -- per-type flat retaliation (with range); total retaliation % comes via the map.
    retaliation =
      [ "+" <> showRange lo hi <> " " <> effectDisplay ["retaliation"] tok <> " Retaliation"
      | (stem, tok) <- damageElems
      , let (lo, hi) = sumRange related ["retaliation"] stem
      , hi > 0
      ]

    render k
      | hardExcluded k = []
      | Just (tmpl, opts) <- lookup k effectStringMap =
          let v = effValue k in [(displayOrder k, formatEffect tmpl opts v) | v /= 0]
      | genericExcluded k = []
      | Just line <- generic k = [(displayOrder k, line)]
      | otherwise = []

    -- a "*Min" map field (e.g. leech) is summed on its Min component.
    effValue = sumField related

    -- display ordering, ported from gd-edit's effect-display-order.
    displayOrder :: Text -> Int
    displayOrder k
      | "characterStrength" `T.isPrefixOf` k = 100
      | "characterLife" `T.isPrefixOf` k = 200
      | "characterManaRegen" `T.isPrefixOf` k = 300
      | "character" `T.isPrefixOf` k = 400
      | "offensive" `T.isPrefixOf` k = 500
      | "defensive" `T.isPrefixOf` k = 600
      | otherwise = 700

    -- camelCase-component fallback (ported from gd-edit's generic-effect): typed
    -- defensive maximum-resistance and duration-reduction stats. Other unmapped
    -- fields are dropped, exactly as gd-edit drops them.
    generic k =
      let comps = splitCamel k
          v = sumField related k
       in if v == 0
            then Nothing
            else case comps of
              ("defensive" : _)
                | "resist" `elem` comps && "max" `elem` comps
                , Just ty <- effectName comps ->
                    Just (formatEffect ("%s Maximum " <> ty <> " Resistance") [Signed, Percentage] v)
                | "duration" `elem` comps
                , Just ty <- effectName comps ->
                    Just (formatEffect ("%s Reduction in " <> ty <> " Duration") [Signed, Percentage] v)
              -- % retaliation per type (flat per-type is handled by the retaliation block)
              ("retaliation" : _)
                | "modifier" `elem` comps
                , Just ty <- effectName comps ->
                    Just (formatEffect ("%s " <> ty <> " Retaliation") [Signed, Percentage] v)
              _ -> Nothing

    -- fields rendered elsewhere; never shown by this function (even if mapped).
    hardExcluded k =
      k `elem` effectIgnoreFields
        || k `elem` resistFields -- shown on the resists line
        || isDamageField k -- shown on the damage line
        || isRetaliationType k -- shown by the retaliation block above
        || isSkillField k -- shown on the skills line
        || k `elem` ["defensiveProtection", "defensiveBonusProtection"] -- folded into armor

    -- additionally skipped by the generic fallback (but allowed if explicitly mapped).
    genericExcluded k =
      "Max" `T.isSuffixOf` k -- the Max half of a range/min pair
        || "Chance" `T.isSuffixOf` k -- proc chance handled with its companion
        || ("duration" `elem` comps && ("min" `elem` comps || "max" `elem` comps)) -- DoT companions
        || "slow" `elem` comps -- enemy-debuff slows (handled separately in gd-edit)
      where
        comps = splitCamel k

    resistFields = concatMap snd resistFieldMap
    damageStems = map fst damageElems ++ ["Elemental"]
    isDamageField k =
      or
        [ k == p <> s <> suf
        | p <- ["offensive", "offensiveBase", "offensiveBonus"]
        , s <- damageStems
        , suf <- ["Min", "Max", "Modifier"]
        ]
    isRetaliationType k =
      or ["retaliation" <> s <> suf == k | s <- damageStems, suf <- ["Min", "Max"]]
    isSkillField k =
      any (`T.isPrefixOf` k) ["augment", "modifiedSkill", "modifierSkill"]
        || k `elem` ["itemSkillName", "buffSkillName", "petSkillName", "petBonusName"]

dedupe :: [Text] -> [Text]
dedupe = nub

--------------------------------------------------------------------------------
-- Skill bonuses
--------------------------------------------------------------------------------

-- resolve a skill record name to a display name (follows buff/pet redirects).
skillDisplayName :: GameDb -> Text -> Text
skillDisplayName db = go (4 :: Int)
  where
    go 0 path = leaf path
    go n path = case lookupRecord path db of
      Nothing -> leaf path
      Just r ->
        case textField "skillDisplayName" r of
          Just nm | not (T.null nm) -> nm
          _ ->
            case textField "buffSkillName" r `orElse` textField "petSkillName" r of
              Just redirect -> go (n - 1) redirect
              Nothing -> leaf path
    leaf = last . T.splitOn "/"

-- skill bonuses contributed by a single record
recordSkillBonuses :: GameDb -> Record -> [Text]
recordSkillBonuses db r =
  allSkills ++ augSkills ++ augMasteries ++ granted
  where
    -- non-zero level, formatted; a 0 (e.g. an inactive set-bonus tier) is dropped.
    numLevel f = case fieldNum f r of
      Just v | v /= 0 -> Just (showNum v)
      _ -> Nothing
    allSkills =
      ["+" <> lvl <> " to all Skills" | Just lvl <- [numLevel "augmentAllLevel"]]
    augSkills =
      [ "+" <> lvl <> " " <> skillDisplayName db nm
      | i <- idxs
      , Just nm <- [textField ("augmentSkillName" <> i) r]
      , Just lvl <- [numLevel ("augmentSkillLevel" <> i)]
      ]
    augMasteries =
      [ "+" <> lvl <> " to " <> skillDisplayName db nm
      | i <- idxs
      , Just nm <- [textField ("augmentMasteryName" <> i) r]
      , Just lvl <- [numLevel ("augmentMasteryLevel" <> i)]
      ]
    granted =
      ["Grants " <> skillDisplayName db nm | Just nm <- [textField "itemSkillName" r]]
    idxs = map (T.pack . show) [1 .. 6 :: Int]

skillBonuses :: GameDb -> [(Text, Record)] -> [Text]
skillBonuses db related = concatMap (recordSkillBonuses db . snd) related

-- | Derive every filterable attribute for an owned item.
itemAttrs :: Item -> GameDb -> ItemAttrs
itemAttrs it db =
  ItemAttrs
    { iaDisplayName = fromMaybe (itemBaseName it) (itemDisplayName it db)
    , iaClass = cls
    , iaType = cls >>= classSubtype
    , iaClassification = base >>= textField "itemClassification"
    , iaLevelRequirement =
        base >>= lookupField "levelRequirement" >>= fmap fromIntegral . valueInt
    , iaResists =
        Set.fromList
          [ ty | (ty, fields) <- resistFieldMap, anyFieldPresent related fields ]
    , iaResistBonuses = resistBonuses related
    , iaDamage =
        Set.fromList
          [ ty | (ty, stems) <- damageFieldMap, damagePresent related stems ]
    , iaDamageBonuses = damageBonuses related
    , iaBonuses = characterBonuses related
    , iaSkillBonuses = skillBonuses db related
    , iaIsSet = any (HM.member "itemSetName" . snd) related
    , iaSetRecord = setRecordName it db
    , iaBitmap = base >>= \b -> firstJust [textField f b | f <- ["bitmap", "artifactBitmap", "relicBitmap"]]
    }
  where
    related = relatedRecords it db
    base = baseRecord it db
    cls = base >>= textField "Class"

