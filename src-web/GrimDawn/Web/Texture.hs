{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}

-- | Convert a Grim Dawn @.tex@ asset to PNG bytes for the browser.
--
-- A @.tex@ file is a 12-byte header (@\"TEX\\2\"@, a zero word, then the payload
-- size) wrapping a standard DDS image. We strip the header, parse the DDS, decode
-- the top mip level to RGBA8 and re-encode it as PNG. The formats Grim Dawn's
-- @Items.arc@ actually uses are covered: the block-compressed BC1\/BC2\/BC3
-- (@DXT1\/DXT3\/DXT5@) and the uncompressed 24- and 32-bit RGB(A) layouts.
module GrimDawn.Web.Texture
  ( decodeTexture
  ) where

import Codec.Picture (Image (..), PixelRGBA8, encodePng)
import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Bits (countTrailingZeros, popCount, shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Vector.Storable as SV
import qualified Data.Vector.Storable.Mutable as MV
import Data.Word (Word32, Word64, Word8)

pngMagic :: BS.ByteString
pngMagic = BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

-- | Best-effort decode of asset bytes to PNG. Returns 'Nothing' when the format
-- isn't one we handle, leaving the caller to 404.
decodeTexture :: BS.ByteString -> Maybe BS.ByteString
decodeTexture bs
  | pngMagic `BS.isPrefixOf` bs = Just bs
  | otherwise = do
      dds <- toDds bs
      img <- decodeDds dds
      pure (BL.toStrict (encodePng img))

-- A GD @.tex@ wraps a DDS behind a 12-byte header; accept either a wrapped
-- @.tex@ or a bare DDS. The embedded magic's first three bytes are @\"DDS\"@
-- (Grim Dawn stores an @R@ where the standard has a trailing space).
toDds :: BS.ByteString -> Maybe BS.ByteString
toDds bs
  | "DDS" `BS.isPrefixOf` bs = Just bs
  | "TEX" `BS.isPrefixOf` bs, "DDS" `BS.isPrefixOf` BS.drop 12 bs = Just (BS.drop 12 bs)
  | otherwise = Nothing

-- DDS_PIXELFORMAT.dwFlags bits we care about.
ddpfFourCC, ddpfRGB :: Word32
ddpfFourCC = 0x4
ddpfRGB = 0x40

-- | Decode the top mip of a DDS image to RGBA8. Field offsets are relative to the
-- start of the DDS data (4-byte magic + 124-byte DDS_HEADER, pixels at 128).
decodeDds :: BS.ByteString -> Maybe (Image PixelRGBA8)
decodeDds dds
  | w <= 0 || h <= 0 = Nothing
  | pfFlags .&. ddpfFourCC /= 0 = case fourcc of
      "DXT1" -> Just (buildImage w h (blocksFill 8 bc1 w h pixels))
      "DXT3" -> Just (buildImage w h (blocksFill 16 bc2 w h pixels))
      "DXT5" -> Just (buildImage w h (blocksFill 16 bc3 w h pixels))
      _ -> Nothing
  | pfFlags .&. ddpfRGB /= 0, bpp == 3 || bpp == 4 =
      Just (buildImage w h (rgbFill bpp rMask gMask bMask aMask w h pixels))
  | otherwise = Nothing
  where
    h = fromIntegral (le32 dds 12)
    w = fromIntegral (le32 dds 16)
    pfFlags = le32 dds 80
    fourcc = BS.take 4 (BS.drop 84 dds)
    bpp = fromIntegral (le32 dds 88) `div` 8 :: Int
    -- Grim Dawn leaves the channel masks zeroed; fall back to the D3D default
    -- (A8R8G8B8 / R8G8B8, i.e. B,G,R[,A] byte order) when none are set.
    (rMask, gMask, bMask, aMask)
      | hdrR == 0 && hdrG == 0 && hdrB == 0 =
          (0x00ff0000, 0x0000ff00, 0x000000ff, if bpp == 4 then 0xff000000 else 0)
      | otherwise = (hdrR, hdrG, hdrB, hdrA)
    hdrR = le32 dds 92
    hdrG = le32 dds 96
    hdrB = le32 dds 100
    hdrA = le32 dds 104
    pixels = BS.drop 128 dds

-- | Allocate a @w*h@ RGBA8 buffer (opaque black) and run a filler over it.
buildImage :: Int -> Int -> (forall s. MV.MVector s Word8 -> ST s ()) -> Image PixelRGBA8
buildImage w h fill =
  Image w h $
    runST $ do
      v <- MV.replicate (w * h * 4) 0
      fill v
      SV.unsafeFreeze v

writePixel :: MV.MVector s Word8 -> Int -> (Word8, Word8, Word8, Word8) -> ST s ()
writePixel mv p (r, g, b, a) = do
  MV.write mv p r
  MV.write mv (p + 1) g
  MV.write mv (p + 2) b
  MV.write mv (p + 3) a
{-# INLINE writePixel #-}

-- | Drive a block-compressed decoder. Each 4x4 block decodes to a pixel function
-- (index 0..15, row-major) which we scatter into the image, clamping the partial
-- blocks at non-multiple-of-4 edges.
blocksFill ::
  Int -> -- block size in bytes
  (BS.ByteString -> Int -> Int -> (Word8, Word8, Word8, Word8)) -> -- data, blockOffset, pixel -> rgba
  Int ->
  Int ->
  BS.ByteString ->
  MV.MVector s Word8 ->
  ST s ()
blocksFill bsz px w h dat mv =
  forM_ [0 .. bh - 1] $ \by ->
    forM_ [0 .. bw - 1] $ \bx -> do
      let off = (by * bw + bx) * bsz
      when (off + bsz <= BS.length dat) $
        forM_ [0 .. 15] $ \i -> do
          let x = bx * 4 + (i .&. 3)
              y = by * 4 + (i `shiftR` 2)
          when (x < w && y < h) $
            writePixel mv ((y * w + x) * 4) (px dat off i)
  where
    bw = (w + 3) `div` 4
    bh = (h + 3) `div` 4

-- Expand a 5- or 6-bit channel to 8 bits by bit replication.
rgb565 :: Int -> (Word8, Word8, Word8)
rgb565 c =
  ( ex5 (c `shiftR` 11)
  , fromIntegral (((g `shiftL` 2) .|. (g `shiftR` 4)) .&. 0xff)
  , ex5 c
  )
  where
    g = (c `shiftR` 5) .&. 0x3f
    ex5 v = let x = v .&. 0x1f in fromIntegral ((x `shiftL` 3) .|. (x `shiftR` 2))

-- | Parse a BC1 4-byte-colour + 4-byte-index block at @o@. When @punch@ is set
-- (standalone DXT1) the @c0 <= c1@ case yields a transparent 4th colour; in
-- BC2\/BC3 the colour block is always the opaque 4-colour interpretation.
colorBlock :: Bool -> BS.ByteString -> Int -> Int -> (Word8, Word8, Word8, Word8)
colorBlock punch dat o =
  \i -> palette (fromIntegral ((bits `shiftR` (2 * i)) .&. 3) :: Int)
  where
    c0 = le16 dat o
    c1 = le16 dat (o + 2)
    bits = le32 dat (o + 4)
    (r0, g0, b0) = rgb565 c0
    (r1, g1, b1) = rgb565 c1
    opaque = c0 > c1 || not punch
    blend wa wb a b = fromIntegral ((wa * fromIntegral a + wb * fromIntegral b) `div` (wa + wb) :: Int)
    c2
      | opaque = (blend 2 1 r0 r1, blend 2 1 g0 g1, blend 2 1 b0 b1, 255)
      | otherwise = (blend 1 1 r0 r1, blend 1 1 g0 g1, blend 1 1 b0 b1, 255)
    c3
      | opaque = (blend 1 2 r0 r1, blend 1 2 g0 g1, blend 1 2 b0 b1, 255)
      | otherwise = (0, 0, 0, 0)
    palette 0 = (r0, g0, b0, 255)
    palette 1 = (r1, g1, b1, 255)
    palette 2 = c2
    palette _ = c3

bc1 :: BS.ByteString -> Int -> Int -> (Word8, Word8, Word8, Word8)
bc1 = colorBlock True

-- BC2: 8 bytes of explicit 4-bit alpha, then a BC1 colour block.
bc2 :: BS.ByteString -> Int -> Int -> (Word8, Word8, Word8, Word8)
bc2 dat o =
  let color = colorBlock False dat (o + 8)
   in \i ->
        let byte = BS.index dat (o + (i `shiftR` 1))
            nib = if even i then byte .&. 0x0f else byte `shiftR` 4
            (r, g, b, _) = color i
         in (r, g, b, (nib `shiftL` 4) .|. nib)

-- BC3: 2 alpha endpoints + 16 3-bit alpha indices, then a BC1 colour block.
bc3 :: BS.ByteString -> Int -> Int -> (Word8, Word8, Word8, Word8)
bc3 dat o =
  let a0 = fromIntegral (BS.index dat o)
      a1 = fromIntegral (BS.index dat (o + 1))
      idxBits =
        foldl' (\acc k -> acc .|. (fromIntegral (BS.index dat (o + 2 + k)) `shiftL` (8 * k))) (0 :: Word64) [0 .. 5]
      pal = alphaPalette a0 a1
      color = colorBlock False dat (o + 8)
   in \i ->
        let (r, g, b, _) = color i
            ai = fromIntegral ((idxBits `shiftR` (3 * i)) .&. 7)
         in (r, g, b, pal !! ai)

-- The 8-entry BC3 alpha palette.
alphaPalette :: Int -> Int -> [Word8]
alphaPalette a0 a1 =
  map fromIntegral $
    [a0, a1]
      ++ if a0 > a1
        then [((7 - k) * a0 + k * a1) `div` 7 | k <- [1 .. 6]]
        else [((5 - k) * a0 + k * a1) `div` 5 | k <- [1 .. 4]] ++ [0, 255]

-- | Decode an uncompressed RGB(A) surface using the pixel-format channel masks.
rgbFill :: Int -> Word32 -> Word32 -> Word32 -> Word32 -> Int -> Int -> BS.ByteString -> MV.MVector s Word8 -> ST s ()
rgbFill bpp rMask gMask bMask aMask w h dat mv =
  forM_ [0 .. h - 1] $ \y ->
    forM_ [0 .. w - 1] $ \x -> do
      let o = (y * w + x) * bpp
      when (o + bpp <= BS.length dat) $ do
        let px = leN dat o bpp
            a = if aMask == 0 then 255 else channel aMask px
        writePixel mv ((y * w + x) * 4) (channel rMask px, channel gMask px, channel bMask px, a)

-- Extract a masked channel and scale it to a full 8-bit range.
channel :: Word32 -> Word32 -> Word8
channel mask px
  | mask == 0 = 255
  | otherwise = fromIntegral ((v * 255) `div` maxv)
  where
    v = (px .&. mask) `shiftR` countTrailingZeros mask
    maxv = (1 `shiftL` popCount mask) - 1

le16 :: BS.ByteString -> Int -> Int
le16 b o = fromIntegral (BS.index b o) .|. (fromIntegral (BS.index b (o + 1)) `shiftL` 8)

le32 :: BS.ByteString -> Int -> Word32
le32 b o = leN b o 4

-- Read @n@ (<= 4) little-endian bytes into a Word32.
leN :: BS.ByteString -> Int -> Int -> Word32
leN b o n = foldl' (\acc k -> acc .|. (fromIntegral (BS.index b (o + k)) `shiftL` (8 * k))) 0 [0 .. n - 1]
