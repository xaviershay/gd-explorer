-- | Filterable item inventory report: list owned items (across all characters
-- and the shared stash) filtered by type, resistance, damage, set membership,
-- character, and level. Each item is rendered as a short block showing its
-- rarity, slot, level, location, resistances, damage bonuses, and skill bonuses.
module GrimDawn.Report.Items
  ( ItemFilter (..)
  , emptyFilter
  , ItemRow (..)
  , itemRows
  , matchesFilter
  , renderItems
  ) where

import Data.List (sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Aggregate (Location, OwnedItem (..), locationLabel)
import GrimDawn.Db (GameDb)
import GrimDawn.Gdc (itemStackCount)
import GrimDawn.Item (ItemAttrs (..), itemAttrs)
import GrimDawn.Report.Color (applyColor, colorByType, rarityColor)

-- | A conjunction of filter criteria; 'emptyFilter' matches everything.
data ItemFilter = ItemFilter
  { ifType :: !(Maybe Text) -- item type / slot (e.g. "helm", "ring", "sword")
  , ifResists :: ![Text] -- require ALL of these resistance types
  , ifDamage :: ![Text] -- require ALL of these damage types
  , ifSkills :: ![Text] -- require ALL of these as substrings of a skill bonus
  , ifSetOnly :: !Bool -- only set items
  , ifChar :: !(Maybe Text) -- restrict to a character (substring of location)
  , ifMinLevel :: !(Maybe Int)
  , ifMaxLevel :: !(Maybe Int)
  }
  deriving (Show, Eq)

emptyFilter :: ItemFilter
emptyFilter = ItemFilter Nothing [] [] [] False Nothing Nothing Nothing

-- | One item in the report.
data ItemRow = ItemRow
  { irName :: !Text
  , irRarity :: !(Maybe Text)
  , irType :: !Text
  , irLevel :: !(Maybe Int)
  , irResists :: ![Text]
  , irDamage :: ![Text] -- rendered damage bonuses (+/%)
  , irBonuses :: ![Text] -- rendered stat bonuses (armor, OA/DA, xp, ...)
  , irSkills :: ![Text] -- rendered skill bonuses
  , irLocation :: !Text
  , irCount :: !Int
  }
  deriving (Show, Eq)

-- common slot synonyms a user might type -> the DB Class subtype.
typeSynonym :: Text -> Text
typeSynonym q = case T.toLower q of
  "helm" -> "head"
  "helmet" -> "head"
  "boots" -> "feet"
  "gloves" -> "hands"
  "pants" -> "legs"
  "necklace" -> "amulet"
  "armor" -> "chest"
  "chestguard" -> "chest"
  other -> other

-- | Does an item (with its attributes + location) satisfy the filter?
matchesFilter :: ItemFilter -> ItemAttrs -> Location -> Bool
matchesFilter ItemFilter {..} a loc =
  typeOk && resistOk && damageOk && skillOk && setOk && charOk && levelOk
  where
    lvl = maybe 0 id (iaLevelRequirement a)
    typeOk = case ifType of
      Nothing -> True
      Just q ->
        let qn = typeSynonym q
            ty = maybe "" T.toLower (iaType a)
            cls = maybe "" T.toLower (iaClass a)
         in qn `T.isInfixOf` ty || T.toLower q `T.isInfixOf` cls
    resistOk = all (`Set.member` iaResists a) (map T.toLower ifResists)
    damageOk = all (`Set.member` iaDamage a) (map T.toLower ifDamage)
    -- a skill query matches if it is a substring of any rendered skill bonus;
    -- an empty query ("") matches any item that grants at least one skill bonus.
    skillOk = all skillMatch (map T.toLower ifSkills)
    skillMatch q = any (\s -> q `T.isInfixOf` T.toLower s) (iaSkillBonuses a)
    setOk = not ifSetOnly || iaIsSet a
    charOk = case ifChar of
      Nothing -> True
      Just c -> T.toLower c `T.isInfixOf` T.toLower (locationLabel loc)
    levelOk =
      maybe True (lvl >=) ifMinLevel && maybe True (lvl <=) ifMaxLevel

-- | Produce the filtered, sorted rows for the report.
itemRows :: GameDb -> ItemFilter -> [OwnedItem] -> [ItemRow]
itemRows db flt owned =
  sortOn (\r -> (irType r, irName r)) $
    [ toRow oi a
    | oi <- owned
    , let a = itemAttrs (oiItem oi) db
    , matchesFilter flt a (oiLocation oi)
    ]
  where
    toRow oi a =
      ItemRow
        { irName = iaDisplayName a
        , irRarity = iaClassification a
        , irType = maybe "" id (iaType a)
        , irLevel = iaLevelRequirement a
        , irResists = iaResistBonuses a
        , irDamage = iaDamageBonuses a
        , irBonuses = iaBonuses a
        , irSkills = iaSkillBonuses a
        , irLocation = locationLabel (oiLocation oi)
        , irCount = max 1 (fromIntegral (itemStackCount (oiItem oi)))
        }

-- | Render the rows as a per-item block listing, e.g.
--
-- > Whisperer of Secrets  [Legendary]  head  lvl 65  — Odie (equipped)  x1
-- >     resists: aether
-- >     damage:  32% Pierce
-- >     skills:  +3 Laceration, +2 Ring of Steel, Grants Ring of Steel
--
-- When @useColor@ is set, the @[rarity]@ tag is wrapped in its in-game colour.
renderItems :: Bool -> [ItemRow] -> Text
renderItems useColor = T.unlines . concatMap renderOne
  where
    renderOne r = headerLine r : detailLines r
    headerLine r =
      T.unwords $
        catMaybes
          [ Just (irName r)
          , rarityTag <$> irRarity r
          , nonEmpty (irType r)
          , (\n -> "lvl " <> T.pack (show n)) <$> irLevel r
          , Just ("— " <> irLocation r)
          , Just ("x" <> T.pack (show (irCount r)))
          ]
    rarityTag x =
      let tag = "[" <> x <> "]"
       in applyColor useColor (rarityColor x) tag
    detailLines r =
      catMaybes
        [ field "resists" (T.intercalate ", " (map (colorByType useColor) (irResists r)))
        , field "damage " (T.intercalate ", " (map (colorByType useColor) (irDamage r)))
        , field "bonuses" (T.intercalate ", " (irBonuses r))
        , field "skills " (T.intercalate ", " (irSkills r))
        ]
    field label v
      | T.null v = Nothing
      | otherwise = Just ("    " <> label <> ": " <> v)
    nonEmpty t = if T.null t then Nothing else Just t
