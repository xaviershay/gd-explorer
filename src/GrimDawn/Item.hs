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
import GrimDawn.Arz (Record, lookupField, valueInt, valueText)
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
    , iaIsSet = any (HM.member "itemSetName" . snd) related
    , iaSetRecord = setRecordName it db
    }
  where
    related = relatedRecords it db
    base = baseRecord it db
    cls = base >>= textField "Class"

