-- | Single-character report: the gear a character has equipped, the skills they
-- have invested in (grouped by mastery), and their devotions (grouped by
-- constellation, with the celestial power each grants).
module GrimDawn.Report.Character
  ( renderCharacter
  ) where

import Data.Char (isDigit)
import qualified Data.HashMap.Strict as HM
import Data.List (nub)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Arz (Record, Value (..), lookupField, valueText)
import GrimDawn.Db (GameDb (..), lookupRecord)
import GrimDawn.Gdc (Character (..), Skill (..), emptyItemName)
import GrimDawn.Item
  ( ItemAttrs (..)
  , characterBonuses
  , damageBonuses
  , itemAttrs
  , resistBonuses
  , setRecordName
  , skillBonuses
  , skillDisplayName
  )
import GrimDawn.Report.Color (applyColor, colorByType, rarityColor)
import GrimDawn.Report.Sets (setMemberNames)

-- | Render a character's header, equipped gear, skills, and devotions.
renderCharacter :: Bool -> GameDb -> Character -> Text
renderCharacter useColor db c =
  T.unlines $
    headerLine
      : ""
      : "Equipped:"
      : concatMap itemBlock equipped
      ++ blank setLines
      ++ setLines
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
      detailLinesFrom (iaResistBonuses a) (iaDamageBonuses a) (iaBonuses a) (iaSkillBonuses a)

    -- the indented "resists/damage/bonuses/skills" lines shared by items and sets.
    detailLinesFrom resists damage bonuses skills =
      catMaybes
        [ field "resists" (T.intercalate ", " (map (colorByType useColor) resists))
        , field "damage " (T.intercalate ", " (map (colorByType useColor) damage))
        , field "bonuses" (T.intercalate ", " bonuses)
        , field "skills " (T.intercalate ", " skills)
        ]

    --------------------------------------------------------------------------
    -- Set bonuses (aggregated per set, not repeated on each item)
    --------------------------------------------------------------------------
    setLines
      | null setBlocks = []
      | otherwise = "Set Bonuses:" : concat setBlocks

    -- set records of equipped pieces, in first-seen order, with equipped count.
    equippedSetRecs = [s | it <- equipped, Just s <- [setRecordName it db]]
    setEntries = [(s, length (filter (== s) equippedSetRecs)) | s <- nub equippedSetRecs]

    setBlocks = [b | (rec, cnt) <- setEntries, let b = renderSet rec cnt, not (null b)]

    renderSet setRec cnt =
      case lookupRecord setRec db of
        Nothing -> []
        Just r ->
          let related = [(setRec, resolveSetTier cnt r)]
              detail =
                detailLinesFrom
                  (resistBonuses related)
                  (damageBonuses related)
                  (characterBonuses related)
                  (skillBonuses db related)
              total = length (setMemberNames r)
              name = maybe setRec id (lookupField "setName" r >>= valueText)
              header = "  " <> name <> "  (" <> tshow cnt <> "/" <> tshow total <> ")"
           in if null detail then [] else header : map ("    " <>) detail

    -- collapse each array bonus field to the value for the equipped piece count
    -- (arrays are indexed by pieces-1; scalars and string fields pass through).
    resolveSetTier :: Int -> Record -> Record
    resolveSetTier cnt = HM.map pick
      where
        idx = max 0 (cnt - 1)
        pick (VList xs) | not (null xs) = xs !! min idx (length xs - 1)
        pick v = v

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
    lastSeg p = case T.splitOn "/" p of [] -> p; ws -> last ws

tshow :: Show a => a -> Text
tshow = T.pack . show
