-- | Aggregate every owned item across all characters and the shared transfer
-- stash, tagging each with where it lives.
module GrimDawn.Aggregate
  ( Location (..)
  , OwnedItem (..)
  , locationLabel
  , loadOwnedItems
  ) where

import Control.Monad (forM)
import Data.Text (Text)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

import GrimDawn.Gdc
  ( Character (..)
  , Item
  , loadCharacterFile
  )
import GrimDawn.Stash (loadStashFile, stashTabItems)

-- | Where an owned item was found.
data Location
  = Equipped !Text -- character name
  | Inventory !Text -- character name
  | PersonalStash !Text -- character name
  | SharedStash -- the transfer stash
  deriving (Show, Eq)

-- | An item together with its provenance.
data OwnedItem = OwnedItem
  { oiItem :: !Item
  , oiLocation :: !Location
  }
  deriving (Show, Eq)

locationLabel :: Location -> Text
locationLabel = \case
  Equipped c -> c <> " (equipped)"
  Inventory c -> c <> " (inventory)"
  PersonalStash c -> c <> " (stash)"
  SharedStash -> "shared stash"

-- | Load every owned item from @save/main/*/player.gdc@ and @save/transfer.gst@
-- under @dataDir@. Missing pieces are skipped; a hard parse error is returned.
loadOwnedItems :: FilePath -> IO (Either String [OwnedItem])
loadOwnedItems dataDir = do
  let saveDir = dataDir </> "save"
      mainDir = saveDir </> "main"
      transfer = saveDir </> "transfer.gst"
  charItemsE <- loadChars mainDir
  case charItemsE of
    Left e -> pure (Left e)
    Right charItems -> do
      sharedE <- loadShared transfer
      pure $ case sharedE of
        Left e -> Left e
        Right shared -> Right (charItems ++ shared)

loadChars :: FilePath -> IO (Either String [OwnedItem])
loadChars mainDir = do
  exists <- doesDirectoryExist mainDir
  if not exists
    then pure (Right [])
    else do
      entries <- listDirectory mainDir
      results <- forM entries $ \entry -> do
        let gdc = mainDir </> entry </> "player.gdc"
        present <- doesFileExist gdc
        if not present
          then pure (Right [])
          else fmap (fmap charOwned) (loadCharacterFile gdc)
      pure (concat <$> sequence results)
  where
    charOwned :: Character -> [OwnedItem]
    charOwned c =
      let nm = charName c
       in [OwnedItem i (Equipped nm) | i <- charEquipped c]
            ++ [OwnedItem i (Inventory nm) | i <- charInventory c]
            ++ [OwnedItem i (PersonalStash nm) | i <- charPersonalStash c]

loadShared :: FilePath -> IO (Either String [OwnedItem])
loadShared transfer = do
  present <- doesFileExist transfer
  if not present
    then pure (Right [])
    else do
      r <- loadStashFile transfer
      pure $ fmap (\tabs -> [OwnedItem i SharedStash | t <- tabs, i <- stashTabItems t]) r
