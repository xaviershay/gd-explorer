module GrimDawn.AggregateSpec (spec) where

import Data.List (nub)
import GrimDawn.Aggregate
import Test.Hspec
import TestHelpers (dataDir, savePath, withDataFile)

locKind :: Location -> String
locKind = \case
  Equipped _ -> "equipped"
  Inventory _ -> "inventory"
  PersonalStash _ -> "personalStash"
  SharedStash -> "sharedStash"

spec :: Spec
spec =
  describe "loadOwnedItems (real save data)" $
    it "returns every owned item, populated for each source type" $
      withDataFile (savePath "transfer.gst") $ \_ -> do
        r <- loadOwnedItems dataDir
        case r of
          Left e -> expectationFailure e
          Right owned -> do
            length owned > 0 `shouldBe` True
            -- a stable golden total across this data set
            length owned `shouldBe` 944
            let kinds = nub (map (locKind . oiLocation) owned)
            -- all four source kinds are represented
            mapM_ (\k -> (k `elem` kinds) `shouldBe` True)
              ["equipped", "inventory", "personalStash", "sharedStash"]
