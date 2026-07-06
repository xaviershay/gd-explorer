module OaDaFit.Csv
  ( Obs (..)
  , parseDataCsv
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | One row of ground-truth in-game values from data.csv.
data Obs = Obs
  { obsName :: !Text
  , obsOA :: !Double
  , obsDA :: !Double
  , obsHealth :: !Double
  , obsEnergy :: !Double
  , obsGear :: !Bool
  }
  deriving (Show, Eq)

-- | Parse data.csv. Header is dropped; blank lines skipped. Columns are
-- Character,OA,DA,Health,Energy,Gear split on commas (character names contain
-- no commas). Malformed rows are dropped.
parseDataCsv :: Text -> [Obs]
parseDataCsv t =
  [ o
  | line <- drop 1 (T.lines t)
  , not (T.null (T.strip line))
  , Just o <- [parseRow line]
  ]
  where
    parseRow line = case map T.strip (T.splitOn "," line) of
      [name, oa, da, hp, en, gear] ->
        Obs name <$> num oa <*> num da <*> num hp <*> num en
                 <*> Just (gear == T.pack "true")
      _ -> Nothing
    num = readMaybe . T.unpack
