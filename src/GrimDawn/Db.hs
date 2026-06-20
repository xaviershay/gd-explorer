-- | Merged database + localization facade. Loads the base game and every
-- present DLC tier (GDX1/2/3), builds one localization table, then decodes the
-- @.arz@ records with tag strings already resolved to display names.
module GrimDawn.Db
  ( GameDb (..)
  , loadGameDb
  , lookupRecord
  , recordField
  ) where

import Control.Monad (filterM, foldM)
import qualified Data.ByteString as BS
import Data.Text (Text)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import GrimDawn.Arc (loadLocalization, mergeLocalization)
import GrimDawn.Arz
  ( LocalizationTable
  , Record
  , RecordDb
  , Value
  , loadArz
  , lookupField
  , mergeDbs
  )
import qualified Data.HashMap.Strict as HM

-- | The fully merged game database with its localization table.
data GameDb = GameDb
  { gdbRecords :: !RecordDb
  , gdbText :: !LocalizationTable
  }

-- One content tier: its database file and localization file (relative to the
-- @game/@ directory). Earlier tiers are overridden by later ones.
tiers :: [(FilePath, FilePath)]
tiers =
  [ ("database/database.arz", "resources/Text_EN.arc")
  , ("gdx1/database/GDX1.arz", "gdx1/resources/Text_EN.arc")
  , ("gdx2/database/GDX2.arz", "gdx2/resources/Text_EN.arc")
  , ("gdx3/database/GDX3.arz", "gdx3/resources/Text_EN.arc")
  ]

-- | Load and merge the game database. @dataDir@ is the root holding @game/@
-- (e.g. @data/gd-data@).
loadGameDb :: FilePath -> IO (Either String GameDb)
loadGameDb dataDir = do
  let gameDir = dataDir </> "game"
  -- present localization files, in tier order
  presentArcs <- filterM doesFileExist (map ((gameDir </>) . snd) tiers)
  presentArzs <- filterM doesFileExist (map ((gameDir </>) . fst) tiers)
  if null presentArzs
    then pure (Left ("no .arz database found under " ++ gameDir))
    else do
      locE <- loadAll loadLocalization presentArcs
      case fmap mergeLocalization locE of
        Left e -> pure (Left e)
        Right loc -> do
          dbE <- loadAll (loadArz loc) presentArzs
          pure $ case dbE of
            Left e -> Left e
            Right dbs -> Right (GameDb (mergeDbs dbs) loc)

-- load + parse each file with a pure parser, collecting results or first error
loadAll :: (BS.ByteString -> Either String a) -> [FilePath] -> IO (Either String [a])
loadAll parse = foldM step (Right [])
  where
    step (Left e) _ = pure (Left e)
    step (Right acc) fp = do
      raw <- BS.readFile fp
      pure $ case parse raw of
        Left e -> Left (fp ++ ": " ++ e)
        Right x -> Right (acc ++ [x])

-- | Look up a record by its record name.
lookupRecord :: Text -> GameDb -> Maybe Record
lookupRecord name = HM.lookup name . gdbRecords

-- | Look up a field within a record by record name.
recordField :: Text -> Text -> GameDb -> Maybe Value
recordField name field db = lookupRecord name db >>= lookupField field
