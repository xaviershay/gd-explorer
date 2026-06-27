module GrimDawn.ArcSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import GrimDawn.Arc (loadArchiveFile)
import Test.Hspec
import TestHelpers (gamePath, withDataFile)

spec :: Spec
spec =
  describe "loadArchive (real Text_EN.arc)" $
    it "extracts named entries with non-empty contents" $
      withDataFile (gamePath "resources/Text_EN.arc") $ \fp -> do
        r <- loadArchiveFile fp
        case r of
          Left e -> expectationFailure e
          Right entries -> do
            HM.size entries > 0 `shouldBe` True
            -- every entry has a name and some bytes
            all (not . T.null) (HM.keys entries) `shouldBe` True
            all (not . BS.null) (HM.elems entries) `shouldBe` True
            -- localization records are key=value text
            any (BS.isInfixOf "=" ) (HM.elems entries) `shouldBe` True
