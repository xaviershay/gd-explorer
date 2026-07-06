module OaDaFit.Inputs
  ( Inputs (..)
  , characterInputs
  , loadInputs
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.List (find)
import GrimDawn.Db (GameDb, loadGameDb)
import GrimDawn.Aggregate (loadCharacters)
import GrimDawn.Gdc (Character (..), Skill (..))
import GrimDawn.Item (sumField)
import GrimDawn.Report.Stats
  ( StatSummary (..)
  , statSummary
  , statSources
  , devotionSources
  , masterySources
  , skillSources
  , plainSources
  , parseBuffs
  , Difficulty (Normal)
  )

data Inputs = Inputs
  { inName :: !Text
  , inGeared :: !Bool
  , inLevel :: !Double
  , inPhys :: !Double
  , inCun :: !Double
  , inSpi :: !Double
  , inFlatOA :: !Double
  , inPctOA :: !Double
  , inFlatDA :: !Double
  , inPctDA :: !Double
  , inMasteryRanks :: !Double -- summed invested ranks across mastery bars
  }
  deriving (Show, Eq)

-- | Reconstruct one character's raw formula inputs in the permanent-buff state,
-- either geared (all equipped items) or ungeared (gear stripped). Ungeared
-- recomputes skill buff ranks without gear's +skill bonuses, matching how the
-- game behaves when gear is removed.
characterInputs :: GameDb -> Character -> Bool -> Inputs
characterInputs db c geared =
  Inputs
    { inName = charName c
    , inGeared = geared
    , inLevel = fromIntegral (charLevel c)
    , inPhys = attr (T.pack "Physique")
    , inCun = attr (T.pack "Cunning")
    , inSpi = attr (T.pack "Spirit")
    , inFlatOA = sumField src (T.pack "characterOffensiveAbility")
    , inPctOA = sumField src (T.pack "characterOffensiveAbilityModifier")
    , inFlatDA = sumField src (T.pack "characterDefensiveAbility")
    , inPctDA = sumField src (T.pack "characterDefensiveAbilityModifier")
    , inMasteryRanks = masteryRankTotal c
    }
  where
    perm = either error id (parseBuffs "permanent")
    gearSrc = if geared then statSources db (charEquipped c) else []
    dev = devotionSources db c
    mas = masterySources db c
    nonSkill = gearSrc ++ dev ++ mas
    sk = skillSources perm nonSkill db c
    src = plainSources (nonSkill ++ sk)
    summary = statSummary Normal c src
    attr label = maybe 0 snd (find ((== label) . fst) (ssAttributes summary))

-- | Total invested ranks across a character's mastery bars (the
-- @_classtraining_@ skill records).
masteryRankTotal :: Character -> Double
masteryRankTotal c =
  fromIntegral . sum $
    [ skLevel s
    | s <- charSkills c
    , T.pack "_classtraining_" `T.isInfixOf` skName s
    , skLevel s > 0
    ]

-- | Load the game DB and all characters from a data dir, dying on error.
loadInputs :: FilePath -> IO (GameDb, [Character])
loadInputs dir = do
  db <- loadGameDb dir >>= orDie
  chars <- loadCharacters dir >>= orDie
  pure (db, chars)
  where
    orDie = either (ioError . userError) pure
