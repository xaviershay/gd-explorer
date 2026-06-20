module GrimDawn.BinarySpec (spec) where

import qualified Data.ByteString as BS
import Data.Word (Word8)
import GrimDawn.Binary
import Test.Hspec

bs :: [Word8] -> BS.ByteString
bs = BS.pack

spec :: Spec
spec = do
  describe "integer primitives (little-endian)" $ do
    it "reads int32" $
      runGet int32 (bs [0x01, 0x00, 0x00, 0x00]) `shouldBe` Right 1
    it "reads negative int32" $
      runGet int32 (bs [0xff, 0xff, 0xff, 0xff]) `shouldBe` Right (-1)
    it "reads int16" $
      runGet int16 (bs [0x00, 0x01]) `shouldBe` Right 256
    it "reads negative int16" $
      runGet int16 (bs [0xfe, 0xff]) `shouldBe` Right (-2)
    it "reads int8" $
      runGet int8 (bs [0x80]) `shouldBe` Right (-128)
    it "reads word32" $
      runGet word32 (bs [0xff, 0xff, 0xff, 0xff]) `shouldBe` Right 4294967295
    it "reads int64" $
      runGet int64 (bs [0x01, 0, 0, 0, 0, 0, 0, 0]) `shouldBe` Right 1

  describe "float32" $
    it "round-trips a known bit pattern (1.0)" $
      -- IEEE-754 1.0f = 0x3F800000, little-endian bytes
      runGet float32 (bs [0x00, 0x00, 0x80, 0x3f]) `shouldBe` Right 1.0

  describe "strings" $ do
    it "reads an int32-length-prefixed ascii string" $
      runGet asciiString (bs [0x03, 0, 0, 0, 0x61, 0x62, 0x63])
        `shouldBe` Right "abc"
    it "reads an empty ascii string" $
      runGet asciiString (bs [0, 0, 0, 0]) `shouldBe` Right ""
    it "reads a utf-16le string (char-count prefix)" $
      -- "hi" = 2 chars => 4 bytes
      runGet utf16leString (bs [0x02, 0, 0, 0, 0x68, 0x00, 0x69, 0x00])
        `shouldBe` Right "hi"

  describe "bytes / skip / position" $ do
    it "takes n bytes and advances" $
      runGet (skip 2 >> bytes 2) (bs [1, 2, 3, 4]) `shouldBe` Right (bs [3, 4])
    it "reports remaining" $
      runGet (skip 1 >> remaining) (bs [1, 2, 3]) `shouldBe` Right 2

  describe "errors" $ do
    it "fails on overrun" $
      case runGet (bytes 5) (bs [1, 2, 3]) of
        Left _ -> True `shouldBe` True
        Right _ -> expectationFailure "expected overrun failure"

  describe "lengthPrefixedArray" $
    it "reads a prefixed array of int32" $
      runGet (lengthPrefixedArray int32)
        (bs [0x02, 0, 0, 0, 0x0a, 0, 0, 0, 0x14, 0, 0, 0])
        `shouldBe` Right [10, 20]
