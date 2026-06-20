module GrimDawn.Lz4Spec (spec) where

import qualified Data.ByteString as BS
import Data.Word (Word8)
import GrimDawn.Lz4 (decompress)
import Test.Hspec

bs :: [Word8] -> BS.ByteString
bs = BS.pack

spec :: Spec
spec = do
  describe "raw LZ4 block decompression" $ do
    it "decodes a literals-only block" $
      -- token 0x50 = literal length 5, match length 0; then 5 literal bytes.
      -- A literals-only block is the whole thing (last sequence has no match).
      decompress 5 (bs [0x50, 0x41, 0x42, 0x43, 0x44, 0x45])
        `shouldBe` Right (bs [0x41, 0x42, 0x43, 0x44, 0x45]) -- "ABCDE"

    it "decodes a block with a back-reference (overlapping run)" $
      -- 1 literal 'A' (0x41), then a match: offset 1, match length 4+4=8.
      -- token 0x14 = litlen 1, matchlen nibble 4 (=> 4+minmatch4 = 8).
      -- literal: 0x41 ; offset: 0x01 0x00 ; -> "A" then copy 8 bytes from -1
      -- giving "AAAAAAAAA" (9 bytes total).
      decompress 9 (bs [0x14, 0x41, 0x01, 0x00])
        `shouldBe` Right (BS.replicate 9 0x41)

    it "fails cleanly when the declared size is wrong" $
      case decompress 99 (bs [0x50, 0x41, 0x42, 0x43, 0x44, 0x45]) of
        Left _ -> True `shouldBe` True
        Right _ -> expectationFailure "expected a size-mismatch failure"

    it "handles the empty block" $
      decompress 0 BS.empty `shouldBe` Right BS.empty
