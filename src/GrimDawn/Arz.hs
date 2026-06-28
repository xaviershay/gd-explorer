-- | Game database @.arz@ reader. Port of gd-edit's @io/arz.clj@.
--
-- The file is: a header, a record-header table, a string table, and a blob of
-- LZ4-compressed record bodies. We read every record header (cheap) but only
-- fully decode record bodies under @records/items/@ (items, affixes, sets) to
-- keep load time and memory manageable, mirroring the plan.
module GrimDawn.Arz
  ( Value (..)
  , Record
  , RecordDb
  , LocalizationTable
  , loadArz
  , listArzRecordNames
  , mergeDbs
  , lookupField
  , valueText
  , valueInt
  , valueFloat
  , stripColorTags
  ) where

import Control.Monad (replicateM)
import qualified Data.ByteString as BS
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Vector (Vector)
import qualified Data.Vector as V
import GrimDawn.Binary
import qualified GrimDawn.Lz4 as Lz4

-- | A single record field value.
data Value
  = VInt !Int32
  | VFloat !Float
  | VString !Text
  | VList ![Value]
  deriving (Show, Eq)

-- | A database record: field name -> value.
type Record = HashMap Text Value

-- | The merged record database: record name -> record.
type RecordDb = HashMap Text Record

-- | Localization tag -> display string (built by "GrimDawn.Arc").
type LocalizationTable = HashMap Text Text

--------------------------------------------------------------------------------
-- Header / tables
--------------------------------------------------------------------------------

data Header = Header
  { hRecordTableStart :: !Int
  , hRecordTableEntries :: !Int
  , hStringTableStart :: !Int
  }

readHeader :: Get Header
readHeader = do
  _unknown <- word16
  _version <- word16
  recStart <- fromIntegral <$> int32
  _recSize <- int32
  recEntries <- fromIntegral <$> int32
  strStart <- fromIntegral <$> int32
  _strSize <- int32
  pure (Header recStart recEntries strStart)

readStringTable :: Int -> Get (Vector Text)
readStringTable start = do
  setPos start
  n <- fromIntegral <$> word32
  V.fromList <$> replicateM n readOne
  where
    readOne = do
      len <- fromIntegral <$> word32
      TE.decodeLatin1 <$> bytes len

data RecHeader = RecHeader
  { rhName :: !Text
  , rhOffset :: !Int
  , rhCompressed :: !Int
  , rhDecompressed :: !Int
  }

readRecordHeaders :: Header -> Vector Text -> Get [RecHeader]
readRecordHeaders hdr strs = do
  setPos (hRecordTableStart hdr)
  replicateM (hRecordTableEntries hdr) readOne
  where
    readOne = do
      nameIdx <- fromIntegral <$> int32
      _type <- asciiString
      offset <- fromIntegral <$> int32
      csize <- fromIntegral <$> int32
      dsize <- fromIntegral <$> int32
      _u1 <- int32
      _u2 <- int32
      pure (RecHeader (strs V.! nameIdx) offset csize dsize)

--------------------------------------------------------------------------------
-- Record body
--------------------------------------------------------------------------------

-- Decode a single decompressed record body into field/value pairs.
parseRecordBody :: Vector Text -> LocalizationTable -> Get [(Text, Value)]
parseRecordBody strs loc = go []
  where
    go acc = do
      done <- isEmpty
      if done
        then pure (reverse acc)
        else do
          ty <- word16
          cnt <- fromIntegral <$> word16
          fnIdx <- fromIntegral <$> word32
          vals <- replicateM cnt (readVal ty)
          let fname = strs V.! fnIdx
              value = case vals of
                [v] -> v
                _ -> VList vals
          if keep value
            then go ((fname, value) : acc)
            else go acc

    readVal ty
      | ty == 1 = VFloat <$> float32
      | ty == 2 = do
          idx <- fromIntegral <$> word32
          let s = strs V.! idx
          pure $ VString (stripColorTags (resolveTag s))
      | otherwise = VInt <$> int32

    resolveTag s
      | T.isPrefixOf "tag" (T.toLower s) = HM.lookupDefault s s loc
      | otherwise = s

    -- mirror gd-edit: drop scalar zero / empty-string values; keep lists.
    keep (VInt 0) = False
    keep (VFloat 0) = False
    keep (VString s) = not (T.null s)
    keep _ = True

decodeRecord
  :: Header -> Vector Text -> LocalizationTable -> BS.ByteString -> RecHeader
  -> Either String Record
decodeRecord _hdr strs loc raw rh = do
  let compressed = BS.take (rhCompressed rh) (BS.drop (rhOffset rh + 24) raw)
  body <- Lz4.decompress (rhDecompressed rh) compressed
  fields <- runGet (parseRecordBody strs loc) body
  pure (HM.fromList fields)

--------------------------------------------------------------------------------
-- Top-level load
--------------------------------------------------------------------------------

-- record-name prefixes whose bodies we fully decode (items + the skill records
-- that items' skill bonuses reference). Everything else is skipped.
wantedPrefixes :: [Text]
wantedPrefixes =
  [ "records/items/"
  , "records/skills/"
  , "records/creatures/npcs/merchants/"
  , "records/game/gamefactions"
  ]

-- | List every record name in an @.arz@ file without decoding any bodies.
listArzRecordNames :: BS.ByteString -> Either String [Text]
listArzRecordNames raw = do
  hdr <- runGet readHeader raw
  strs <- runGet (readStringTable (hStringTableStart hdr)) raw
  rhs <- runGet (readRecordHeaders hdr strs) raw
  pure (map rhName rhs)

-- | Parse an @.arz@ file, decoding only the record bodies we need
-- (see 'wantedPrefixes').
loadArz :: LocalizationTable -> BS.ByteString -> Either String RecordDb
loadArz loc raw = do
  hdr <- runGet readHeader raw
  strs <- runGet (readStringTable (hStringTableStart hdr)) raw
  rhs <- runGet (readRecordHeaders hdr strs) raw
  let wanted = filter (\rh -> any (`T.isPrefixOf` rhName rh) wantedPrefixes) rhs
  pairs <- mapM (\rh -> (,) (rhName rh) <$> decodeRecord hdr strs loc raw rh) wanted
  pure (HM.fromList pairs)

-- | Merge several databases; later entries win on key collision.
mergeDbs :: [RecordDb] -> RecordDb
mergeDbs [] = HM.empty
mergeDbs (d : ds) = foldl (\acc next -> HM.union next acc) d ds

--------------------------------------------------------------------------------
-- Field accessors
--------------------------------------------------------------------------------

lookupField :: Text -> Record -> Maybe Value
lookupField = HM.lookup

valueText :: Value -> Maybe Text
valueText (VString t) = Just t
valueText _ = Nothing

-- | Strip Grim Dawn's inline colour-control sequences (@^X@ where X is any
-- single character, e.g. @^k@, @^o@, @^l@ used in @description@ fields to
-- change colour mid-string).  These are display directives, not text, and leak
-- as literal characters (e.g. @"^kMark of Dreeg"@) if left in.  Applied to
-- every parsed VString so callers never have to remember.
stripColorTags :: Text -> Text
stripColorTags = go
  where
    go t = case T.break (== '^') t of
      (a, b)
        | T.null b -> a
        | T.length b == 1 -> a -- trailing '^' with no code char
        | otherwise -> a <> go (T.drop 2 b)

valueInt :: Value -> Maybe Int32
valueInt (VInt i) = Just i
valueInt _ = Nothing

valueFloat :: Value -> Maybe Float
valueFloat (VFloat f) = Just f
valueFloat (VInt i) = Just (fromIntegral i)
valueFloat _ = Nothing
