-- | Reader for @formulas.gst@, the account-shared file of learned crafting
-- blueprints. Same XOR cipher as @.gdc@/@.gst@ (see "GrimDawn.Cipher").
--
-- gd-edit does not parse this file, so there is no reference implementation to
-- port. Rather than commit to an exact block layout, we exploit a property of
-- the cipher: within a single (non-nested) framed block the body decrypts
-- byte-for-byte, so string /content/ comes out intact even though the integer
-- fields around it are decoded with the wrong XOR width. We therefore walk the
-- top-level block framing (whose length/checksum fields are read without
-- advancing the cipher) and scan each block body for @records/...dbr@ strings.
-- This is robust to the precise per-formula record layout. If the framing does
-- not match (a future format change), parsing fails cleanly and callers treat
-- it as "no known blueprints".
module GrimDawn.Formulas
  ( parseFormulas
  , loadKnownFormulas
  , craftableItems
  , scanRecordNames
  ) where

import Data.Char (isAlphaNum)
import Data.List (nubBy)
import Data.Text (Text)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import GrimDawn.Aggregate (Location (..), OwnedItem (..))
import GrimDawn.Arz (lookupField, valueText)
import GrimDawn.Cipher
import GrimDawn.Db (GameDb, lookupRecord)
import GrimDawn.Gdc (itemBaseName, itemWithName)

-- | Parse the known crafting blueprints out of raw @formulas.gst@ bytes,
-- returning the formula (and/or crafted-item) record names it references.
parseFormulas :: BS.ByteString -> Either String [Text]
parseFormulas raw
  -- Real @formulas.gst@ files are *plaintext* GD block data ("begin_block" and
  -- "records/...dbr" paths appear verbatim), unlike the XOR-enciphered .gdc/.gst
  -- saves. So scan the raw bytes directly first.
  | not (null plain) = Right plain
  -- Fall back to the enciphered-stream interpretation in case a variant is
  -- encrypted (decode each framed block body, then scan).
  | otherwise = do
      (cipher, pos0) <- initCipher raw
      (bodies, _, _) <- runDec (decInt *> walkBlocks) raw pos0 cipher
      pure (dedup (concatMap (scanRecordNames . TE.decodeLatin1) bodies))
  where
    plain = dedup (scanRecordNames (TE.decodeLatin1 raw))
    dedup = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- Walk top-level framed blocks (@id@, @length@ read without advancing state,
-- @body@, @checksum@), returning each decrypted body. Stops at end of file or
-- the first malformed frame.
walkBlocks :: Dec [BS.ByteString]
walkBlocks = do
  remaining <- decRemaining
  if remaining < 12
    then pure []
    else do
      _id <- decInt
      len <- fromIntegral <$> decU32NoAdvance
      avail <- decRemaining
      if len < 0 || len + 4 > avail
        then pure []
        else do
          body <- decBytes len
          _checksum <- rawWord32
          (body :) <$> walkBlocks

-- Extract every @records/...dbr@ token from decoded text.
scanRecordNames :: Text -> [Text]
scanRecordNames t =
  case T.breakOn "records/" t of
    (_, rest)
      | T.null rest -> []
      | otherwise ->
          let run = T.takeWhile isNameChar rest
              after = T.drop (T.length run) rest
           in case T.breakOn ".dbr" run of
                (pre, suf)
                  | T.null suf -> scanRecordNames after
                  | otherwise -> (pre <> ".dbr") : scanRecordNames after
  where
    isNameChar c = isAlphaNum c || c `elem` ("/_.-" :: String)

-- | Load the learned blueprints from @<dataDir>/save/formulas.gst@. A missing
-- file yields an empty list (blueprints are optional); a present-but-unreadable
-- file yields the parse error.
loadKnownFormulas :: FilePath -> IO (Either String [Text])
loadKnownFormulas dataDir = do
  let fp = dataDir </> "save" </> "formulas.gst"
  present <- doesFileExist fp
  if not present
    then pure (Right [])
    else parseFormulas <$> BS.readFile fp

-- | The items a set of learned formulas can craft, as synthetic 'Craftable'
-- owned items. A blueprint record (carrying @artifactName@) resolves to the item
-- it crafts; any other referenced item record resolves to itself. Records not
-- present in the database are dropped, and results are de-duplicated by basename.
craftableItems :: GameDb -> [Text] -> [OwnedItem]
craftableItems db names =
  nubBy (\a b -> itemBaseName (oiItem a) == itemBaseName (oiItem b))
    [ OwnedItem (itemWithName target) Craftable
    | n <- names
    , Just r <- [lookupRecord n db]
    , let target = maybe n id (lookupField "artifactName" r >>= valueText)
    , Just _ <- [lookupRecord target db]
    ]
