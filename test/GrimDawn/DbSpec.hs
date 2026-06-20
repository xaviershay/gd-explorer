module GrimDawn.DbSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import GrimDawn.Arc (loadLocalization)
import GrimDawn.Arz (Value (..))
import GrimDawn.Db
import Test.Hspec
import TestHelpers (dataDir, gamePath, withDataFile)

spec :: Spec
spec = do
  describe "loadLocalization (base Text_EN.arc)" $
    it "resolves a known base-game tag to English text" $
      withDataFile (gamePath "resources/Text_EN.arc") $ \fp -> do
        raw <- BS.readFile fp
        case loadLocalization raw of
          Left e -> expectationFailure e
          Right table -> do
            HM.size table > 1000 `shouldBe` True
            HM.lookup "tagHeadB005" table `shouldBe` Just "Murderer's Coif"

  describe "loadGameDb (merged db + text)" $
    it "loads records and resolves item-name tags to display names" $
      withDataFile (gamePath "database/database.arz") $ \_ -> do
        r <- loadGameDb dataDir
        case r of
          Left e -> expectationFailure e
          Right db -> do
            HM.size (gdbRecords db) > 1000 `shouldBe` True
            -- itemNameTag has been resolved from "tag..." to a display name
            case recordField "records/items/gearhead/b005_head.dbr" "itemNameTag" db of
              Just (VString name) -> do
                T.isPrefixOf "tag" name `shouldBe` False
                name `shouldBe` "Murderer's Coif"
              _ -> expectationFailure "missing/!string itemNameTag"
