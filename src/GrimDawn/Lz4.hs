module GrimDawn.Lz4
  ( decompress
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, castPtr)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall unsafe "gd_lz4_decompress_block"
  c_lz4_decompress_block
    :: Ptr Word8 -> CInt -> Ptr Word8 -> CInt -> IO CInt

-- | Decompress a raw LZ4 block when the decompressed size is known.
--
-- > decompress decompressedSize compressedBlock
decompress :: Int -> BS.ByteString -> Either String BS.ByteString
decompress dsize src
  | dsize < 0 = Left "Lz4.decompress: negative decompressed size"
  | dsize == 0 = Right BS.empty
  | otherwise = unsafePerformIO $
      BSU.unsafeUseAsCStringLen src $ \(srcPtr, srcLen) -> do
        out <- BSI.mallocByteString dsize
        n <- withForeignPtr out $ \outPtr ->
          c_lz4_decompress_block
            (castPtr srcPtr) (fromIntegral srcLen)
            outPtr (fromIntegral dsize)
        let n' = fromIntegral n :: Int
        pure $
          if n' == dsize
            then Right (BSI.fromForeignPtr out 0 dsize)
            else Left $
              "Lz4.decompress: expected " ++ show dsize
                ++ " bytes but decoder returned " ++ show n'
{-# NOINLINE decompress #-}
