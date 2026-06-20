-- | The Grim Dawn save-file XOR stream cipher, used by both @.gdc@ (character)
-- and @.gst@ (transfer stash) files. See PLAN.md Appendix A for the exact
-- algorithm.
--
-- The key property exploited throughout the readers: the cipher state advances
-- purely as a function of the /ciphertext/ bytes in file order, so any region
-- can be skipped by feeding its raw bytes through the table without decoding.
module GrimDawn.Cipher
  ( Cipher (..)
  , Dec
  , runDec
  , initCipher
  , decInt
  , decByte
  , decBool
  , decFloat
  , decBytes
  , decAscii
  , decUtf16le
  , decStaticBytes
    -- * Block-framing helpers
  , rawWord32
  , decU32NoAdvance
  , decIntNoAdvance
  , advanceOver
  , getState
  , decPos
  , decRemaining
  ) where

import Data.Bits (rotateR, shiftL, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32, Word8)
import GHC.Float (castWord32ToFloat)

-- | Immutable 256-entry table plus the mutable running state.
data Cipher = Cipher
  { cTable :: !(VU.Vector Word32)
  , cState :: !Word32
  }

-- | A decrypting reader threading the read offset and cipher through a strict
-- 'BS.ByteString'.
newtype Dec a = Dec
  { unDec :: BS.ByteString -> Int -> Cipher -> Either String (a, Int, Cipher) }

instance Functor Dec where
  fmap f (Dec g) = Dec $ \bs i c -> case g bs i c of
    Left e -> Left e
    Right (a, i', c') -> Right (f a, i', c')

instance Applicative Dec where
  pure x = Dec $ \_ i c -> Right (x, i, c)
  Dec gf <*> Dec gx = Dec $ \bs i c -> case gf bs i c of
    Left e -> Left e
    Right (f, i', c') -> case gx bs i' c' of
      Left e -> Left e
      Right (x, i'', c'') -> Right (f x, i'', c'')

instance Monad Dec where
  return = pure
  Dec g >>= f = Dec $ \bs i c -> case g bs i c of
    Left e -> Left e
    Right (a, i', c') -> unDec (f a) bs i' c'

instance MonadFail Dec where
  fail msg = Dec $ \_ _ _ -> Left msg

-- | Run a decrypting reader at an explicit starting offset and cipher.
runDec :: Dec a -> BS.ByteString -> Int -> Cipher -> Either String (a, Int, Cipher)
runDec = unDec

getState :: Dec Word32
getState = Dec $ \_ i c -> Right (cState c, i, c)

decPos :: Dec Int
decPos = Dec $ \_ i c -> Right (i, i, c)

decRemaining :: Dec Int
decRemaining = Dec $ \bs i c -> Right (BS.length bs - i, i, c)

-- | Read the 4-byte LE seed at the front of the file, build the table and the
-- initial cipher, returning it together with the offset just past the seed (4).
initCipher :: BS.ByteString -> Either String (Cipher, Int)
initCipher bs
  | BS.length bs < 4 = Left "Cipher.initCipher: file too short for seed"
  | otherwise =
      let raw = leWord32 bs 0
          seed = raw `xor` 0x55555555
       in Right (Cipher (buildTable seed) seed, 4)

-- | @table[i]@ chained from the seed: @v <- rotateR v 1 * 39916801@.
buildTable :: Word32 -> VU.Vector Word32
buildTable seed = VU.iterateN 256 step (step seed)
  where
    -- VU.iterateN n f x = [x, f x, ..] of length n. We want
    -- [f(seed), f(f(seed)), ...]; start at f(seed) and iterate f.
    step v = rotateR v 1 * 39916801

-- helper: little-endian Word32 from a ByteString at an offset (unchecked-safe;
-- callers guarantee 4 bytes are present).
leWord32 :: BS.ByteString -> Int -> Word32
leWord32 bs i =
  fromIntegral (BS.index bs i)
    .|. (fromIntegral (BS.index bs (i + 1)) `shiftL` 8)
    .|. (fromIntegral (BS.index bs (i + 2)) `shiftL` 16)
    .|. (fromIntegral (BS.index bs (i + 3)) `shiftL` 24)

needBytes :: Int -> BS.ByteString -> Int -> Either String ()
needBytes n bs i
  | i + n > BS.length bs = Left ("cipher read out of range at " ++ show i)
  | otherwise = Right ()

-- advance the cipher state over one ciphertext byte
advByte :: Cipher -> Word8 -> Cipher
advByte c b = c { cState = cState c `xor` (cTable c VU.! fromIntegral b) }

-- | Decrypt a u32 (advances state over its 4 LE ciphertext bytes).
decInt :: Dec Int32
decInt = Dec $ \bs i c -> do
  needBytes 4 bs i
  let raw = leWord32 bs i
      plain = raw `xor` cState c
      b0 = BS.index bs i
      b1 = BS.index bs (i + 1)
      b2 = BS.index bs (i + 2)
      b3 = BS.index bs (i + 3)
      c' = foldl advByte c [b0, b1, b2, b3]
  Right (fromIntegral plain, i + 4, c')

-- | Decrypt a single byte.
decByte :: Dec Word8
decByte = Dec $ \bs i c -> do
  needBytes 1 bs i
  let cipherB = BS.index bs i
      plain = cipherB `xor` fromIntegral (cState c .&. 0xff)
  Right (plain, i + 1, advByte c cipherB)

decBool :: Dec Bool
decBool = (/= 0) <$> decByte

-- | Decrypt a float: decrypt the 4-byte bit pattern as a u32, then reinterpret.
decFloat :: Dec Float
decFloat = Dec $ \bs i c -> do
  needBytes 4 bs i
  let raw = leWord32 bs i
      plain = raw `xor` cState c
      c' = foldl advByte c
             [ BS.index bs i, BS.index bs (i + 1)
             , BS.index bs (i + 2), BS.index bs (i + 3) ]
  Right (castWord32ToFloat plain, i + 4, c')

-- | Decrypt @n@ bytes, advancing per ciphertext byte.
decBytes :: Int -> Dec BS.ByteString
decBytes n
  | n < 0 = fail ("decBytes: negative length " ++ show n)
  | otherwise = Dec $ \bs i c -> do
      needBytes n bs i
      let go !k !cur acc
            | k >= n = (BS.pack (reverse acc), cur)
            | otherwise =
                let cipherB = BS.index bs (i + k)
                    plain = cipherB `xor` fromIntegral (cState cur .&. 0xff)
                 in go (k + 1) (advByte cur cipherB) (plain : acc)
          (out, c') = go 0 c []
      Right (out, i + n, c')

-- | Decrypt @n@ raw bytes without producing a value's text form (same advance
-- as 'decBytes'); used for fixed-length fields such as the 16-byte mystery.
decStaticBytes :: Int -> Dec BS.ByteString
decStaticBytes = decBytes

-- | ASCII string with a decrypted int32 byte-length prefix.
decAscii :: Dec Text
decAscii = do
  n <- fromIntegral <$> decInt
  TE.decodeLatin1 <$> decBytes n

-- | UTF-16LE string with a decrypted int32 char-count prefix.
decUtf16le :: Dec Text
decUtf16le = do
  n <- fromIntegral <$> decInt
  TE.decodeUtf16LE <$> decBytes (n * 2)

-- | Read a raw u32 (LE), advancing the offset but NOT the cipher state.
rawWord32 :: Dec Word32
rawWord32 = Dec $ \bs i c -> do
  needBytes 4 bs i
  Right (leWord32 bs i, i + 4, c)

-- | Decrypt a u32 with the current state but WITHOUT advancing state
-- (gd-edit's @read-int-no-update@; also how block lengths are decoded).
decU32NoAdvance :: Dec Word32
decU32NoAdvance = Dec $ \bs i c -> do
  needBytes 4 bs i
  Right (leWord32 bs i `xor` cState c, i + 4, c)

decIntNoAdvance :: Dec Int32
decIntNoAdvance = fromIntegral <$> decU32NoAdvance

-- | Feed @n@ raw bytes through the table (advancing state) without decoding —
-- used to skip blocks we don't model.
advanceOver :: Int -> Dec ()
advanceOver n
  | n < 0 = fail ("advanceOver: negative length " ++ show n)
  | otherwise = Dec $ \bs i c -> do
      needBytes n bs i
      let go !k !cur
            | k >= n = cur
            | otherwise = go (k + 1) (advByte cur (BS.index bs (i + k)))
      Right ((), i + n, go 0 c)
