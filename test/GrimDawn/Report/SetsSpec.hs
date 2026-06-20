module GrimDawn.Report.SetsSpec (spec) where

import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import GrimDawn.Aggregate (Location (..), OwnedItem (..))
import GrimDawn.Arz (Value (..))
import GrimDawn.Db (GameDb (..), loadGameDb)
import GrimDawn.Gdc (Item (..))
import GrimDawn.Report.Sets
import Test.Hspec
import TestHelpers (dataDir, gamePath, withDataFile)

blankItem :: Item
blankItem = Item "" "" "" "" "" 0 "" "" 0 "" 0 0 0 1

-- synthetic DB: one set "Test Set" with two members + their name records.
synthDb :: GameDb
synthDb =
  GameDb
    { gdbRecords =
        HM.fromList
          [ ( "records/items/lootsets/test.dbr"
            , HM.fromList
                [ ("setName", VString "Test Set")
                , ("setMembers", VList [VString "m1", VString "m2"])
                ]
            )
          , ("m1", HM.fromList [("itemNameTag", VString "Member One")])
          , ("m2", HM.fromList [("itemNameTag", VString "Member Two")])
          ]
    , gdbText = HM.empty
    }

owned :: [OwnedItem]
owned =
  [ OwnedItem blankItem {itemBaseName = "m1"} SharedStash
  , OwnedItem blankItem {itemBaseName = "m1"} (Equipped "Odie")
  ]

spec :: Spec
spec = do
  describe "setReport (synthetic)" $ do
    let [sc] = setReport synthDb owned
    it "names the set" $ scName sc `shouldBe` "Test Set"
    it "counts owned distinct pieces vs total" $ do
      scOwnedCount sc `shouldBe` 1
      scTotal sc `shouldBe` 2
      scComplete sc `shouldBe` False
    it "records per-piece count and locations" $ do
      map (\m -> (smName m, smOwned m, smCount m)) (scMembers sc)
        `shouldBe` [("Member One", True, 2), ("Member Two", False, 0)]
    it "renders each piece with count and location, and the missing piece" $
      renderSetReport False [sc]
        `shouldBe` T.unlines
          [ "Test Set  1/2"
          , "    Member One  x2  (Odie (equipped), shared stash)"
          , "    Member Two  missing"
          ]

  describe "setReport (real database)" $
    it "discovers many sets and a known one resolves with the right size" $
      withDataFile (gamePath "database/database.arz") $ \_ -> do
        Right db <- loadGameDb dataDir
        let report = setReport db []
        length report > 100 `shouldBe` True
        case filter ((== "Perdition") . scName) report of
          (sc : _) -> scTotal sc `shouldBe` 5
          [] -> expectationFailure "expected a 'Perdition' set"
