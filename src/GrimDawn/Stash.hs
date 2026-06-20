-- | Transfer (shared) stash @.gst@ reader. Same cipher as @.gdc@; the file is
-- a seed, a magic int (== 2), then a single Block 18 containing the stash tabs.
-- Port of gd-edit's @io/stash.clj@.
module GrimDawn.Stash
  ( StashTab (..)
  , loadStash
  , loadStashFile
  ) where

import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import GrimDawn.Cipher
import GrimDawn.Gdc (Item, decArray, decItem)

-- | One tab of the transfer stash, with its items.
data StashTab = StashTab
  { stashTabIndex :: !Int
  , stashTabItems :: ![Item]
  }
  deriving (Show, Eq)

-- transfer-stash item = item + float X,Y
decTransferItem :: Dec Item
decTransferItem = decItem <* decFloat <* decFloat

-- a stash tab (inventory sack): width + height + array of items
readStashSack :: Dec [Item]
readStashSack = do
  _width <- decInt
  _height <- decInt
  decArray decTransferItem

-- read a length-delimited block, verifying length + checksum; ignores the id.
readFramedBlock :: Dec a -> Dec a
readFramedBlock body = do
  _id <- decInt
  len <- fromIntegral <$> decU32NoAdvance
  start <- decPos
  x <- body
  end <- decPos
  unless (end - start == len) $
    fail ("block length mismatch: expected " ++ show len ++ " got " ++ show (end - start))
  chk <- rawWord32
  st <- getState
  when (chk /= st) $ fail "block checksum mismatch"
  pure x

-- Block 18 body: version, an int32 read with no state advance, mod string,
-- expansion-status byte, then an array of stash tabs (each a framed sub-block).
readBlock18 :: Dec [StashTab]
readBlock18 = do
  _version <- decInt
  _unknown <- decIntNoAdvance
  _mod <- decAscii
  _expansion <- decByte
  sacks <- decArray (readFramedBlock readStashSack)
  pure (zipWith StashTab [0 ..] sacks)

-- | Parse the transfer stash from raw @.gst@ bytes.
loadStash :: BS.ByteString -> Either String [StashTab]
loadStash raw = do
  (cipher, pos0) <- initCipher raw
  (\(c, _, _) -> c) <$> runDec parseAll raw pos0 cipher
  where
    parseAll = do
      magic <- decInt
      when (magic /= 2) $ fail "not a transfer-stash (.gst) file"
      readFramedBlock readBlock18

-- | Load and parse a transfer stash file from disk.
loadStashFile :: FilePath -> IO (Either String [StashTab])
loadStashFile fp = loadStash <$> BS.readFile fp
