module OaDaFit.CsvSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import OaDaFit.Csv (Obs (..), parseDataCsv)

spec :: Spec
spec = describe "parseDataCsv" $ do
  let sample = T.unlines
        [ "Character,OA,DA,Health,Energy,Gear"
        , "Shield,2187,2597,19369,2455,true"
        , "Snake Eyes,2100,1988,13032,4055,true"
        , "Shield,1831,2123,13154,2031,false"
        ]
      rows = parseDataCsv sample
  it "parses one Obs per non-header line" $
    length rows `shouldBe` 3
  it "keeps names with spaces intact" $
    obsName (rows !! 1) `shouldBe` T.pack "Snake Eyes"
  it "parses numeric and boolean fields" $ do
    obsOA (head rows) `shouldBe` 2187
    obsDA (head rows) `shouldBe` 2597
    obsGear (head rows) `shouldBe` True
    obsGear (rows !! 2) `shouldBe` False
