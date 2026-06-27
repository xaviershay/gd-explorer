-- | Localization @.arc@ reader. Port of gd-edit's @io/arc.clj@
-- (@load-localization-table@ path only).
--
-- Each record is a text file of @key=value@ lines; we decompress every record
-- (records may be split into several LZ4 parts) and merge all the lines into a
-- single tag -> string table.
module GrimDawn.Arc
  ( loadLocalization
  , loadLocalizationFile
  , mergeLocalization
  , loadArchive
  , loadArchiveFile
  ) where

import Control.Monad (replicateM, unless)
import qualified Data.ByteString as BS
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GrimDawn.Arz (LocalizationTable)
import GrimDawn.Binary
import qualified GrimDawn.Lz4 as Lz4

data ArcHeader = ArcHeader
  { ahFileEntries :: !Int
  , ahRecordTableSize :: !Int
  , ahStringTableSize :: !Int
  , ahRecordTableOffset :: !Int
  }

readHeader :: Get ArcHeader
readHeader = do
  magic <- int32
  version <- int32
  unless (magic == 0x435241 && version == 3) $
    fail "not an ARC v3 file"
  fileEntries <- fromIntegral <$> int32
  _dataRecords <- int32
  recTableSize <- fromIntegral <$> int32
  strTableSize <- fromIntegral <$> int32
  recTableOffset <- fromIntegral <$> int32
  pure (ArcHeader fileEntries recTableSize strTableSize recTableOffset)

data RecHeader = RecHeader
  { rhEntryType :: !Int
  , rhOffset :: !Int
  , rhCompressed :: !Int
  , rhDecompressed :: !Int
  , rhFileParts :: !Int
  , rhFirstPartIndex :: !Int
  , rhStrLen :: !Int -- filename length in the string table
  , rhStrOff :: !Int -- filename offset within the string table
  }

readRecordHeaders :: ArcHeader -> Get [RecHeader]
readRecordHeaders hdr = do
  setPos (ahRecordTableOffset hdr + ahRecordTableSize hdr + ahStringTableSize hdr)
  replicateM (ahFileEntries hdr) readOne
  where
    readOne = do
      entryType <- fromIntegral <$> int32
      offset <- fromIntegral <$> int32
      csize <- fromIntegral <$> int32
      dsize <- fromIntegral <$> int32
      _hash <- int32
      _filetime <- int64
      fileParts <- fromIntegral <$> int32
      firstPart <- fromIntegral <$> int32
      strLen <- fromIntegral <$> int32
      strOff <- fromIntegral <$> int32
      pure (RecHeader entryType offset csize dsize fileParts firstPart strLen strOff)

-- the filename of a record, read from the string table (which immediately
-- follows the record/file-parts table).
entryName :: BS.ByteString -> ArcHeader -> RecHeader -> Text
entryName raw hdr rh =
  let start = ahRecordTableOffset hdr + ahRecordTableSize hdr + rhStrOff rh
   in TE.decodeUtf8Lenient (BS.take (rhStrLen rh) (BS.drop start raw))

-- read a file-part header (offset, csize, dsize) at the i-th part slot
readPartHeader :: ArcHeader -> RecHeader -> Int -> Get (Int, Int, Int)
readPartHeader hdr rh i = do
  setPos ((rhFirstPartIndex rh + i) * 12 + ahRecordTableOffset hdr)
  off <- fromIntegral <$> int32
  csize <- fromIntegral <$> int32
  dsize <- fromIntegral <$> int32
  pure (off, csize, dsize)

-- load and decompress the (possibly multi-part) contents of one record
loadRecord :: BS.ByteString -> ArcHeader -> RecHeader -> Either String BS.ByteString
loadRecord raw hdr rh
  | rhEntryType rh == 1 && rhCompressed rh == rhDecompressed rh =
      Right (slice (rhOffset rh) (rhCompressed rh))
  | otherwise = BS.concat <$> mapM loadPart [0 .. rhFileParts rh - 1]
  where
    slice off n = BS.take n (BS.drop off raw)
    loadPart i = do
      (off, csize, dsize) <- runGet (readPartHeader hdr rh i) raw
      let compressed = slice off csize
      if csize == dsize
        then Right compressed
        else Lz4.decompress dsize compressed

-- parse key=value lines into a map
parseLines :: BS.ByteString -> HashMap Text Text
parseLines bs = foldr addLine HM.empty (T.lines (TE.decodeUtf8Lenient bs))
  where
    addLine raw acc =
      let line = T.dropWhileEnd (== '\r') raw
       in case T.breakOn "=" line of
            (k, v)
              | T.null v -> acc -- no '=' on this line
              | otherwise -> HM.insert (T.strip k) (T.strip (T.drop 1 v)) acc

-- | Extract every entry of an @.arc@ as raw (decompressed) bytes, keyed by its
-- filename (e.g. @items/gearhead/bitmaps/d115_head.tex@). Reused for both the
-- localization tables (text entries) and binary assets (textures).
loadArchive :: BS.ByteString -> Either String (HashMap Text BS.ByteString)
loadArchive raw = do
  hdr <- runGet readHeader raw
  rhs <- runGet (readRecordHeaders hdr) raw
  entries <- mapM (\rh -> (,) (entryName raw hdr rh) <$> loadRecord raw hdr rh) rhs
  pure (HM.fromList entries)

-- | Load and extract an @.arc@ archive from disk.
loadArchiveFile :: FilePath -> IO (Either String (HashMap Text BS.ByteString))
loadArchiveFile fp = loadArchive <$> BS.readFile fp

-- | Parse the localization table from raw @.arc@ bytes.
loadLocalization :: BS.ByteString -> Either String LocalizationTable
loadLocalization raw =
  HM.unions . map parseLines . HM.elems <$> loadArchive raw

-- | Load and parse a localization @.arc@ from disk.
loadLocalizationFile :: FilePath -> IO (Either String LocalizationTable)
loadLocalizationFile fp = loadLocalization <$> BS.readFile fp

-- | Merge localization tables; later tables win on key collision.
mergeLocalization :: [LocalizationTable] -> LocalizationTable
mergeLocalization [] = HM.empty
mergeLocalization (t : ts) = foldl (\acc next -> HM.union next acc) t ts
