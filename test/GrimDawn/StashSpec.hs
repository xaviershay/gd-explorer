module GrimDawn.StashSpec (spec) where

import qualified Data.Text as T
import GrimDawn.Gdc (Item (..))
import GrimDawn.Stash
import Test.Hspec
import TestHelpers (transferStashPath, withDataFile)

spec :: Spec
spec =
  describe "loadStashFile (real transfer.gst)" $ do
    it "parses, with at least one tab and plausible item records" $
      withDataFile transferStashPath $ \fp -> do
        r <- loadStashFile fp
        case r of
          Left e -> expectationFailure ("parse failed: " ++ e)
          Right tabs -> do
            length tabs > 0 `shouldBe` True
            let names = concatMap (map itemBaseName . stashTabItems) tabs
            all (T.isPrefixOf "records/") names `shouldBe` True
