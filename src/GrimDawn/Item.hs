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
    -- * Attribute vocabularies
  , resistTypes
  , damageTypes
  ) where

import qualified Data.HashMap.Strict as HM
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
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
  , iaDamage :: !(Set Text) -- offensive damage types present
  , iaDamageBonuses :: ![Text] -- rendered damage bonuses, e.g. "+12-18 Fire", "32% Pierce"
  , iaSkillBonuses :: ![Text] -- rendered skill bonuses, e.g. "+1 to all Skills", "Grants Ring of Steel"
  , iaIsSet :: !Bool
  , iaSetRecord :: !(Maybe Text)
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

-- field stem -> display name
damageDisplayMap :: [(Text, Text)]
damageDisplayMap =
  [ ("Physical", "Physical")
  , ("Fire", "Fire")
  , ("Cold", "Cold")
  , ("Lightning", "Lightning")
  , ("Poison", "Poison")
  , ("Aether", "Aether")
  , ("Chaos", "Chaos")
  , ("Life", "Vitality")
  , ("Pierce", "Pierce")
  , ("Bleeding", "Bleed")
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

-- drop a trailing ".0"
showNum :: Double -> Text
showNum x =
  let r = round x :: Integer
   in if fromIntegral r == x
        then T.pack (show r)
        else T.pack (show x)

-- | Rendered damage bonuses across the item's records, flat (+) then percent (%).
damageBonuses :: [(Text, Record)] -> [Text]
damageBonuses related =
  concatMap flat damageDisplayMap ++ concatMap percent allPercentStems
  where
    flat (stem, disp) =
      let lo = sumField related ("offensive" <> stem <> "Min")
            + sumField related ("offensiveBase" <> stem <> "Min")
          hi = sumField related ("offensive" <> stem <> "Max")
            + sumField related ("offensiveBase" <> stem <> "Max")
       in if hi <= 0
            then []
            else
              [ "+"
                  <> ( if lo > 0 && lo /= hi
                         then showNum lo <> "-" <> showNum hi
                         else showNum hi
                     )
                  <> " "
                  <> disp
              ]
    percent (stem, disp) =
      let p = sumField related ("offensive" <> stem <> "Modifier")
       in [showNum p <> "% " <> disp | p > 0]
    -- percent includes Elemental in addition to the per-type stems
    allPercentStems = damageDisplayMap ++ [("Elemental", "Elemental")]

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
    numLevel f = showNum <$> fieldNum f r
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
    , iaDamage =
        Set.fromList
          [ ty | (ty, stems) <- damageFieldMap, damagePresent related stems ]
    , iaDamageBonuses = damageBonuses related
    , iaSkillBonuses = skillBonuses db related
    , iaIsSet = any (HM.member "itemSetName" . snd) related
    , iaSetRecord = setRecordName it db
    }
  where
    related = relatedRecords it db
    base = baseRecord it db
    cls = base >>= textField "Class"

