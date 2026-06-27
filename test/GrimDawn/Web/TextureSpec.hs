{-# LANGUAGE OverloadedStrings #-}

module GrimDawn.Web.TextureSpec (spec) where

import Codec.Picture (decodePng, dynamicMap, imageHeight, imageWidth)
import Data.Bits (shiftL, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.HashMap.Strict as HM
import Data.List (find)
import qualified Data.Text as T
import Data.Word (Word32)
import GrimDawn.Arc (loadArchiveFile)
import GrimDawn.Web.Server (textureKey)
import GrimDawn.Web.Texture (decodeTexture)
import Test.Hspec
import TestHelpers (gamePath, withDataFile)

-- A .tex's embedded DDS starts 12 bytes in; pull its width/height and the
-- pixel-format tag (the FourCC, or "RGB<bits>" for the uncompressed layouts).
texInfo :: BS.ByteString -> Maybe (String, Int, Int)
texInfo v
  | BS.length v < 140 = Nothing
  | otherwise = Just (fmt, fromIntegral (le32 dds 16), fromIntegral (le32 dds 12))
  where
    dds = BS.drop 12 v
    fmt
      | le32 dds 80 .&. 0x4 /= 0 = BC.unpack (BS.take 4 (BS.drop 84 dds))
      | otherwise = "RGB" ++ show (le32 dds 88)

le32 :: BS.ByteString -> Int -> Word32
le32 b o = foldr (\k a -> a .|. (fromIntegral (BS.index b (o + k)) `shiftL` (8 * k))) 0 [0 .. 3 :: Int]

spec :: Spec
spec = do
  describe "textureKey" $ do
    it "strips the leading items/ segment and lowercases" $
      textureKey "items/GearTorso/Bitmaps/B001_Torso.tex"
        `shouldBe` "geartorso/bitmaps/b001_torso.tex"
    it "leaves a path without an items/ prefix alone (bar casing)" $
      textureKey "Gearhead/x.tex" `shouldBe` "gearhead/x.tex"

  describe "decodeTexture" $ do
    it "rejects non-image bytes" $
      decodeTexture "not a texture at all" `shouldBe` Nothing

    -- One real sample per pixel format Items.arc actually uses; each must decode
    -- to a PNG whose dimensions match the source DDS.
    it "decodes every format in Items.arc to a correctly-sized PNG" $
      withDataFile (gamePath "resources/Items.arc") $ \fp -> do
        Right arc <- loadArchiveFile fp
        let texs = [v | (k, v) <- HM.toList arc, ".tex" `T.isSuffixOf` T.toLower k]
            sampleOf f = find (\v -> fmap (\(g, _, _) -> g) (texInfo v) == Just f) texs
        mapM_ (checkFormat sampleOf) ["DXT1", "DXT3", "DXT5", "RGB24", "RGB32"]

checkFormat :: (String -> Maybe BS.ByteString) -> String -> Expectation
checkFormat sampleOf f =
  case sampleOf f of
    Nothing -> pendingWith ("no " ++ f ++ " sample in archive")
    Just v -> do
      let Just (_, w, h) = texInfo v
      case decodeTexture v of
        Nothing -> expectationFailure (f ++ ": decodeTexture returned Nothing")
        Just png -> do
          BS.take 8 png `shouldBe` BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
          case decodePng png of
            Left e -> expectationFailure (f ++ ": produced invalid PNG: " ++ e)
            Right dyn -> (dynamicMap imageWidth dyn, dynamicMap imageHeight dyn) `shouldBe` (w, h)
