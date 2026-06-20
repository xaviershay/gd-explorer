-- | A small pure, total, little-endian binary reader over a strict
-- 'ByteString'. Modelled on the read half of gd-edit's
-- @structure.clj@ / @bytebuffer-reader-fns@.
module GrimDawn.Binary
  ( Get
  , runGet
  , runGetAt
  , getPos
  , setPos
  , remaining
  , isEmpty
  , atEnd
    -- * Primitives
  , int8
  , int16
  , int32
  , int64
  , word8
  , word16
  , word32
  , float32
  , bytes
  , skip
  , asciiString
  , utf16leString
  , staticAsciiString
  , lengthPrefixedArray
  ) where

import Control.Monad (replicateM)
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as BS
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word16, Word32, Word64, Word8)
import GHC.Float (castWord32ToFloat)

-- | A reader threading a read offset through a strict 'ByteString'.
newtype Get a = Get
  { unGet :: BS.ByteString -> Int -> Either String (a, Int) }

instance Functor Get where
  fmap f (Get g) = Get $ \bs i ->
    case g bs i of
      Left e -> Left e
      Right (a, i') -> Right (f a, i')

instance Applicative Get where
  pure x = Get $ \_ i -> Right (x, i)
  Get gf <*> Get gx = Get $ \bs i ->
    case gf bs i of
      Left e -> Left e
      Right (f, i') -> case gx bs i' of
        Left e -> Left e
        Right (x, i'') -> Right (f x, i'')

instance Monad Get where
  return = pure
  Get g >>= f = Get $ \bs i ->
    case g bs i of
      Left e -> Left e
      Right (a, i') -> unGet (f a) bs i'

instance MonadFail Get where
  fail msg = Get $ \_ _ -> Left msg

-- | Run a reader from offset 0.
runGet :: Get a -> BS.ByteString -> Either String a
runGet g bs = runGetAt g bs 0

-- | Run a reader from an explicit starting offset.
runGetAt :: Get a -> BS.ByteString -> Int -> Either String a
runGetAt (Get g) bs i = fst <$> g bs i

getPos :: Get Int
getPos = Get $ \_ i -> Right (i, i)

setPos :: Int -> Get ()
setPos i = Get $ \_ _ -> Right ((), i)

remaining :: Get Int
remaining = Get $ \bs i -> Right (BS.length bs - i, i)

isEmpty :: Get Bool
isEmpty = (<= 0) <$> remaining

atEnd :: Get Bool
atEnd = isEmpty

-- | Pull @n@ raw bytes, advancing the offset. Fails on overrun.
bytes :: Int -> Get BS.ByteString
bytes n
  | n < 0 = fail ("Binary.bytes: negative length " ++ show n)
  | otherwise = Get $ \bs i ->
      if i + n > BS.length bs
        then Left $
          "Binary.bytes: out of range (wanted " ++ show n
            ++ " at " ++ show i ++ " of " ++ show (BS.length bs) ++ ")"
        else Right (BS.take n (BS.drop i bs), i + n)

skip :: Int -> Get ()
skip n = Get $ \bs i ->
  if i + n > BS.length bs || i + n < 0
    then Left ("Binary.skip: out of range " ++ show n ++ " at " ++ show i)
    else Right ((), i + n)

word8 :: Get Word8
word8 = Get $ \bs i ->
  if i >= BS.length bs
    then Left "Binary.word8: out of range"
    else Right (BS.index bs i, i + 1)

word16 :: Get Word16
word16 = do
  a <- fromIntegral <$> word8
  b <- fromIntegral <$> word8
  pure (a .|. (b `shiftL` 8))

word32 :: Get Word32
word32 = do
  a <- fromIntegral <$> word8
  b <- fromIntegral <$> word8
  c <- fromIntegral <$> word8
  d <- fromIntegral <$> word8
  pure (a .|. (b `shiftL` 8) .|. (c `shiftL` 16) .|. (d `shiftL` 24))

word64 :: Get Word64
word64 = do
  lo <- fromIntegral <$> word32
  hi <- fromIntegral <$> word32
  pure (lo .|. (hi `shiftL` 32))

int8 :: Get Int8
int8 = fromIntegral <$> word8

int16 :: Get Int16
int16 = fromIntegral <$> word16

int32 :: Get Int32
int32 = fromIntegral <$> word32

int64 :: Get Int64
int64 = fromIntegral <$> word64

float32 :: Get Float
float32 = castWord32ToFloat <$> word32

-- | ASCII string with an 'int32' length prefix (byte count).
asciiString :: Get Text
asciiString = do
  n <- fromIntegral <$> int32
  TE.decodeLatin1 <$> bytes n

-- | Fixed-length ASCII string (no prefix).
staticAsciiString :: Int -> Get Text
staticAsciiString n = TE.decodeLatin1 <$> bytes n

-- | UTF-16LE string with an 'int32' length prefix counting *characters*
-- (so the byte count is @2 * length@).
utf16leString :: Get Text
utf16leString = do
  n <- fromIntegral <$> int32
  raw <- bytes (n * 2)
  pure (TE.decodeUtf16LE raw)

-- | An 'int32'-count-prefixed array.
lengthPrefixedArray :: Get a -> Get [a]
lengthPrefixedArray g = do
  n <- fromIntegral <$> int32
  replicateM n g
