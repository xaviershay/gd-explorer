-- | Character @.gdc@ reader. Port of the read half of gd-edit's
-- @io/gdc.clj@, simplified to only fully decode the blocks we need —
-- block 3 (inventory + equipment), block 4 (personal stash), and the skill
-- array of block 8 (skills + devotions) — while skipping every other block by
-- advancing the cipher over its raw body.
module GrimDawn.Gdc
  ( Item (..)
  , emptyItemName
  , Skill (..)
  , Character (..)
  , loadCharacter
  , loadCharacterFile
    -- * Shared item reader (re-used by the stash reader)
  , decItem
  , decArray
  ) where

import Control.Monad (replicateM, unless, when)
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Cipher

-- | A parsed inventory/equipment/stash item. Mirrors gd-edit's @Item@ struct.
-- An item with an empty 'itemBaseName' denotes an empty slot.
data Item = Item
  { itemBaseName :: !Text
  , itemPrefixName :: !Text
  , itemSuffixName :: !Text
  , itemModifierName :: !Text
  , itemTransmuteName :: !Text
  , itemSeed :: !Int32
  , itemRelicName :: !Text
  , itemRelicBonus :: !Text
  , itemRelicSeed :: !Int32
  , itemAugmentName :: !Text
  , itemUnknown :: !Int32
  , itemAugmentSeed :: !Int32
  , itemRelicCompletionLevel :: !Int32
  , itemStackCount :: !Int32
  }
  deriving (Show, Eq)

-- | True when an item slot is empty (no basename).
emptyItemName :: Item -> Bool
emptyItemName = T.null . itemBaseName

-- | A learned skill (or devotion star) from block 8. Mirrors gd-edit's @Skill@
-- struct. Class skills have @skName@ under @records/skills/<mastery>/@; devotion
-- stars have it under @records/skills/devotion/@.
data Skill = Skill
  { skName :: !Text -- skill record path
  , skLevel :: !Int32 -- invested level
  , skEnabled :: !Bool
  , skDevotionLevel :: !Int32
  , skDevotionExperience :: !Int32
  , skSublevel :: !Int32
  , skActive :: !Bool
  , skTransition :: !Bool
  , skAutoCastSkill :: !Text
  , skAutoCastController :: !Text
  }
  deriving (Show, Eq)

-- | A character loaded from a @player.gdc@. Item lists are flattened across
-- their containers (sacks / stash tabs) with empty slots removed.
data Character = Character
  { charName :: !Text
  , charClassName :: !Text
  , charLevel :: !Int32
  , charHardcore :: !Bool
  , charEquipped :: ![Item]
  , charInventory :: ![Item]
  , charPersonalStash :: ![Item]
  , charSkills :: ![Skill]
  , -- | Allocated attributes from the bio block (base + level + spent points,
    -- before mastery/gear bonuses).
    charPhysique :: !Double
  , charCunning :: !Double
  , charSpirit :: !Double
  }
  deriving (Show, Eq)

-- bio block (id 2) values we keep: physique, cunning, spirit.
data Bio = Bio !Double !Double !Double

emptyBio :: Bio
emptyBio = Bio 0 0 0

-- "GDCX" as a little-endian int32.
gdcxMagic :: Int32
gdcxMagic = 0x58434447

--------------------------------------------------------------------------------
-- Item + array primitives
--------------------------------------------------------------------------------

-- | Decode an int32-count-prefixed array.
decArray :: Dec a -> Dec [a]
decArray g = do
  n <- fromIntegral <$> decInt
  replicateM n g

decItem :: Dec Item
decItem =
  Item
    <$> decAscii -- basename
    <*> decAscii -- prefix
    <*> decAscii -- suffix
    <*> decAscii -- modifier
    <*> decAscii -- transmute
    <*> decInt -- seed
    <*> decAscii -- relic-name
    <*> decAscii -- relic-bonus
    <*> decInt -- relic-seed
    <*> decAscii -- augment-name
    <*> decInt -- unknown
    <*> decInt -- augment-seed
    <*> decInt -- relic-completion-level
    <*> decInt -- stack-count

-- equipment item = item + attached bool
decEquipmentItem :: Dec Item
decEquipmentItem = decItem <* decBool

-- inventory / stash item = item + X,Y int32
decGridItem :: Dec Item
decGridItem = decItem <* decInt <* decInt

-- block-8 Skill struct (gd-edit @Skill@): name + level + enabled + devotion
-- level/experience + sublevel + active/transition flags + autocast names.
decSkill :: Dec Skill
decSkill =
  Skill
    <$> decAscii -- name (record path)
    <*> decInt -- level
    <*> decBool -- enabled
    <*> decInt -- devotionLevel
    <*> decInt -- devotionExperience
    <*> decInt -- sublevel
    <*> decBool -- active
    <*> decBool -- transition
    <*> decAscii -- autoCastSkill
    <*> decAscii -- autoCastController

--------------------------------------------------------------------------------
-- Block framing
--------------------------------------------------------------------------------

-- | Read a length-delimited sub-block (id + length + body + checksum) whose
-- body we always decode. Used for inventory sacks and stash tabs (id 0).
readSubBlock :: Dec a -> Dec a
readSubBlock body = do
  _id <- decInt
  len <- fromIntegral <$> decU32NoAdvance
  start <- decPos
  x <- body
  end <- decPos
  unless (end - start == len) $
    fail ("sub-block length mismatch: expected " ++ show len ++ " got " ++ show (end - start))
  verifyChecksum
  pure x

verifyChecksum :: Dec ()
verifyChecksum = do
  chk <- rawWord32
  st <- getState
  when (chk /= st) $ fail "block checksum mismatch"

--------------------------------------------------------------------------------
-- Block 3 (inventory + equipment)
--------------------------------------------------------------------------------

-- Returns (equipment items, inventory items) flattened, empties not yet removed.
readBlock3 :: Dec ([Item], [Item])
readBlock3 = do
  _version <- decInt
  hasData <- decBool
  if not hasData
    then pure ([], [])
    else do
      sackCount <- fromIntegral <$> decInt
      _focused <- decInt
      _selected <- decInt
      sacks <- replicateM sackCount (readSubBlock readInventorySack)
      _useAlt <- decBool
      equipment <- replicateM 12 decEquipmentItem
      _alt1 <- decBool
      alt1set <- replicateM 2 decEquipmentItem
      _alt2 <- decBool
      alt2set <- replicateM 2 decEquipmentItem
      pure (equipment ++ alt1set ++ alt2set, concat sacks)

-- InventorySack: unused bool + array of inventory items
readInventorySack :: Dec [Item]
readInventorySack = do
  _unused <- decBool
  decArray decGridItem

--------------------------------------------------------------------------------
-- Block 4 (personal stash)
--------------------------------------------------------------------------------

readBlock4 :: Dec [Item]
readBlock4 = do
  _version <- decInt
  stashCount <- fromIntegral <$> decInt
  stashes <- replicateM stashCount (readSubBlock readStash)
  pure (concat stashes)

-- Stash tab: width + height + array of grid items
readStash :: Dec [Item]
readStash = do
  _width <- decInt
  _height <- decInt
  decArray decGridItem

--------------------------------------------------------------------------------
-- Block 2 (bio: attributes)
--------------------------------------------------------------------------------

-- Bio block: version, level, experience, the three point pools, then the three
-- attributes and base health/energy. We keep only the attributes; the caller
-- advances over anything after.
readBlock2 :: Dec Bio
readBlock2 = do
  _version <- decInt
  _level <- decInt
  _experience <- decInt
  _attrPoints <- decInt
  _skillPoints <- decInt
  _devotionPoints <- decInt
  _totalDevotionUnlocked <- decInt
  phys <- decFloat
  cun <- decFloat
  spi <- decFloat
  pure (Bio (realToFrac phys) (realToFrac cun) (realToFrac spi))

--------------------------------------------------------------------------------
-- Block 8 (skills + devotions)
--------------------------------------------------------------------------------

-- Skills block: version, then the skill array. The remaining fields
-- (masteries-allowed, reclamation points, item skills) are skipped by the
-- caller, which advances to the framed block end.
readBlock8 :: Dec [Skill]
readBlock8 = do
  _version <- decInt
  decArray decSkill

--------------------------------------------------------------------------------
-- Top-level file
--------------------------------------------------------------------------------

readHeader :: Dec (Text, Bool, Text, Int32, Bool)
readHeader = do
  name <- decUtf16le
  male <- decBool
  className <- decAscii
  level <- decInt
  hardcore <- decBool
  _expansion <- decByte
  pure (name, male, className, level, hardcore)

-- top-level block loop, accumulating block 2 (bio) + 3 (items) + 4 (stash) + 8 (skills)
readBlocks :: Bio -> ([Item], [Item]) -> [Item] -> [Skill] -> Dec (Bio, ([Item], [Item]), [Item], [Skill])
readBlocks acc2 acc3 acc4 acc8 = do
  done <- (<= 0) <$> decRemaining
  if done
    then pure (acc2, acc3, acc4, acc8)
    else do
      blockId <- decInt
      len <- fromIntegral <$> decU32NoAdvance
      start <- decPos
      (acc2', acc3', acc4', acc8') <- case blockId of
        2 -> do
          r <- readBlock2
          cur <- decPos
          advanceOver (len - (cur - start))
          pure (r, acc3, acc4, acc8)
        3 -> do
          r <- readBlock3
          pure (acc2, r, acc4, acc8)
        4 -> do
          r <- readBlock4
          pure (acc2, acc3, r, acc8)
        8 -> do
          r <- readBlock8
          -- skip any trailing fields (masteries-allowed, item skills, ...)
          cur <- decPos
          advanceOver (len - (cur - start))
          pure (acc2, acc3, acc4, r)
        _ -> do
          advanceOver len
          pure (acc2, acc3, acc4, acc8)
      end <- decPos
      unless (end - start == len) $
        fail ("block " ++ show blockId ++ " length mismatch: expected "
                ++ show len ++ " got " ++ show (end - start))
      verifyChecksum
      readBlocks acc2' acc3' acc4' acc8'

-- | Parse a character from the raw bytes of a @player.gdc@ file.
loadCharacter :: BS.ByteString -> Either String Character
loadCharacter raw = do
  (cipher, pos0) <- initCipher raw
  (\(c, _, _) -> c) <$> runDec parseAll raw pos0 cipher
  where
    parseAll :: Dec Character
    parseAll = do
      magic <- decInt
      _version <- decInt
      when (magic /= gdcxMagic) $ fail "not a GDCX character file"
      (name, _male, className, level, hardcore) <- readHeader
      verifyChecksum -- header checksum
      dataVersion <- decInt
      unless (dataVersion `elem` [6, 7, 8]) $
        fail ("unsupported gdc data-version " ++ show dataVersion)
      _mystery <- decStaticBytes 16
      (Bio phys cun spi, (equip, inv), pstash, skills) <- readBlocks emptyBio ([], []) [] []
      let keep = filter (not . emptyItemName)
      pure Character
        { charName = name
        , charClassName = className
        , charLevel = level
        , charHardcore = hardcore
        , charEquipped = keep equip
        , charInventory = keep inv
        , charPersonalStash = keep pstash
        , charSkills = skills
        , charPhysique = phys
        , charCunning = cun
        , charSpirit = spi
        }

-- | Load and parse a character file from disk.
loadCharacterFile :: FilePath -> IO (Either String Character)
loadCharacterFile fp = loadCharacter <$> BS.readFile fp
