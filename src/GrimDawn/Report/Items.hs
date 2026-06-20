-- | Filterable item inventory report: list owned items (across all characters
-- and the shared stash) filtered by type, resistance, damage, set membership,
-- character, and level, rendered as a table.
module GrimDawn.Report.Items
  ( ItemFilter (..)
  , emptyFilter
  , ItemRow (..)
  , itemRows
  , matchesFilter
  , renderItemsTable
  ) where

import Data.List (sortOn)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Aggregate (Location, OwnedItem (..), locationLabel)
import GrimDawn.Db (GameDb)
import GrimDawn.Gdc (itemStackCount)
import GrimDawn.Item (ItemAttrs (..), itemAttrs)

-- | A conjunction of filter criteria; 'emptyFilter' matches everything.
data ItemFilter = ItemFilter
  { ifType :: !(Maybe Text) -- item type / slot (e.g. "helm", "ring", "sword")
  , ifResists :: ![Text] -- require ALL of these resistance types
  , ifDamage :: ![Text] -- require ALL of these damage types
  , ifSetOnly :: !Bool -- only set items
  , ifChar :: !(Maybe Text) -- restrict to a character (substring of location)
  , ifMinLevel :: !(Maybe Int)
  , ifMaxLevel :: !(Maybe Int)
  }
  deriving (Show, Eq)

emptyFilter :: ItemFilter
emptyFilter = ItemFilter Nothing [] [] False Nothing Nothing Nothing

-- | One rendered row of the report.
data ItemRow = ItemRow
  { irName :: !Text
  , irType :: !Text
  , irLevel :: !(Maybe Int)
  , irResists :: ![Text]
  , irDamage :: ![Text]
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
  typeOk && resistOk && damageOk && setOk && charOk && levelOk
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
        , irType = maybe "" id (iaType a)
        , irLevel = iaLevelRequirement a
        , irResists = Set.toList (iaResists a)
        , irDamage = Set.toList (iaDamage a)
        , irLocation = locationLabel (oiLocation oi)
        , irCount = max 1 (fromIntegral (itemStackCount (oiItem oi)))
        }

-- | Render rows as a fixed-width text table.
renderItemsTable :: [ItemRow] -> Text
renderItemsTable rows =
  T.unlines (headerLine : sepLine : map rowLine rows)
  where
    cols =
      [ ("Name", map irName rows)
      , ("Type", map irType rows)
      , ("Lvl", map (maybe "" (T.pack . show) . irLevel) rows)
      , ("Resists", map (T.intercalate "," . irResists) rows)
      , ("Damage", map (T.intercalate "," . irDamage) rows)
      , ("Location", map irLocation rows)
      , ("Cnt", map (T.pack . show . irCount) rows)
      ]
    widths = [maximum (T.length h : map T.length vs) | (h, vs) <- cols]
    pad w t = T.justifyLeft w ' ' t
    headerLine = T.intercalate "  " (zipWith pad widths (map fst cols))
    sepLine = T.intercalate "  " (map (`T.replicate` "-") widths)
    rowLine r =
      T.intercalate "  " $
        zipWith
          pad
          widths
          [ irName r
          , irType r
          , maybe "" (T.pack . show) (irLevel r)
          , T.intercalate "," (irResists r)
          , T.intercalate "," (irDamage r)
          , irLocation r
          , T.pack (show (irCount r))
          ]
