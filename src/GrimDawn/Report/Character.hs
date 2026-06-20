-- | Single-character report: the gear a character has equipped, the skills they
-- have invested in (grouped by mastery), and their devotions (grouped by
-- constellation, with the celestial power each grants).
module GrimDawn.Report.Character
  ( renderCharacter
  ) where

import Data.Char (isDigit)
import qualified Data.HashMap.Strict as HM
import Data.List (foldl', nub)
import Data.Maybe (catMaybes, listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Db (GameDb (..))
import GrimDawn.Gdc (Character (..), Skill (..), emptyItemName)
import GrimDawn.Item (ItemAttrs (..), itemAttrs, skillDisplayName)
import GrimDawn.Report.Color (applyColor, rarityColor, typeColor)

-- | Render a character's header, equipped gear, skills, and devotions.
renderCharacter :: Bool -> GameDb -> Character -> Text
renderCharacter useColor db c =
  T.unlines $
    headerLine
      : ""
      : "Equipped:"
      : concatMap itemBlock equipped
      ++ blank skillLines
      ++ skillLines
      ++ blank devotionLines
      ++ devotionLines
  where
    blank xs = if null xs then [] else [""]

    --------------------------------------------------------------------------
    -- Header
    --------------------------------------------------------------------------
    headerLine =
      charName c
        <> "  —  Level "
        <> tshow (charLevel c)
        <> (if T.null className then "" else "  " <> className)
        <> (if charHardcore c then "  (Hardcore)" else "")
    className = HM.lookupDefault "" (charClassName c) (gdbText db)

    --------------------------------------------------------------------------
    -- Equipped gear
    --------------------------------------------------------------------------
    equipped = filter (not . emptyItemName) (charEquipped c)

    itemBlock it =
      let a = itemAttrs it db
       in ("  " <> headerOf a) : map ("    " <>) (detailsOf a)

    headerOf a =
      T.unwords $
        catMaybes
          [ Just (iaDisplayName a)
          , (\x -> applyColor useColor (rarityColor x) ("[" <> x <> "]")) <$> iaClassification a
          , nonEmpty (maybe "" id (iaType a))
          , (\n -> "lvl " <> tshow n) <$> iaLevelRequirement a
          ]
    detailsOf a =
      catMaybes
        [ field "resists" (T.intercalate ", " (map colorResist (Set.toList (iaResists a))))
        , field "damage " (T.intercalate ", " (map colorDamage (iaDamageBonuses a)))
        , field "skills " (T.intercalate ", " (iaSkillBonuses a))
        ]
    colorResist t = applyColor useColor (typeColor t) t
    colorDamage s = applyColor useColor (typeColor (lastWord s)) s

    --------------------------------------------------------------------------
    -- Skills (grouped by mastery)
    --------------------------------------------------------------------------
    skillLines
      | null masteryBars = []
      | otherwise = "Skills:" : concatMap renderMastery masteryBars

    classSkills = [s | s <- charSkills c, "records/skills/playerclass" `T.isPrefixOf` skName s]
    masteryBars = [s | s <- classSkills, "_classtraining_" `T.isInfixOf` skName s]
    normalSkills = [s | s <- classSkills, not ("_classtraining_" `T.isInfixOf` skName s)]

    renderMastery bar =
      ("  " <> skillDisplayName db (skName bar) <> " (" <> tshow (skLevel bar) <> ")")
        : [ "    +" <> tshow (skLevel s) <> " " <> skillDisplayName db (skName s)
          | s <- normalSkills
          , classSegment (skName s) == classSegment (skName bar)
          ]

    -- the "playerclassNN" path segment that ties a skill to its mastery.
    classSegment p = case filter ("playerclass" `T.isPrefixOf`) (T.splitOn "/" p) of
      (x : _) -> x
      [] -> ""

    --------------------------------------------------------------------------
    -- Devotions (grouped by constellation)
    --------------------------------------------------------------------------
    devotionLines
      | null devStars = []
      | otherwise =
          ("Devotions (" <> tshow (length devStars) <> " points):")
            : map renderConstellation constellations
    devStars = [s | s <- charSkills c, "/devotion/tier" `T.isInfixOf` skName s]

    -- constellation key from a star path, e.g. ".../tier1_19e_skill.dbr" -> "tier1_19".
    constKey s =
      let leaf = lastSeg (skName s)
          base = T.dropEnd 4 leaf -- strip ".dbr"
       in case T.splitOn "_" base of
            (a : b : _) -> a <> "_" <> T.takeWhile isDigit b
            _ -> base
    -- a "*_skill" star is the constellation's granted celestial power.
    isPower s = "_skill" `T.isSuffixOf` T.dropEnd 4 (lastSeg (skName s))

    -- distinct constellation keys, in the order their stars were first seen.
    constellations = foldl' (\acc s -> if constKey s `elem` acc then acc else acc ++ [constKey s]) [] devStars

    renderConstellation k =
      let grp = [s | s <- devStars, constKey s == k]
          name = case filter (not . isPower) grp of
            (s : _) -> skillDisplayName db (skName s)
            [] -> maybe "?" (skillDisplayName db . skName) (listToMaybe grp)
          power = listToMaybe (nub [skillDisplayName db (skName s) | s <- grp, isPower s])
          stars = length grp
       in "  "
            <> name
            <> "  ("
            <> tshow stars
            <> (if stars == 1 then " star)" else " stars)")
            <> maybe "" (\p -> "  grants " <> p) power

    --------------------------------------------------------------------------
    -- helpers
    --------------------------------------------------------------------------
    field label v
      | T.null v = Nothing
      | otherwise = Just (label <> ": " <> v)
    nonEmpty t = if T.null t then Nothing else Just t
    lastWord s = case T.words s of [] -> s; ws -> last ws
    lastSeg p = case T.splitOn "/" p of [] -> p; ws -> last ws

tshow :: Show a => a -> Text
tshow = T.pack . show
