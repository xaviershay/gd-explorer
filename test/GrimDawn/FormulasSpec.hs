module GrimDawn.FormulasSpec (spec) where

import qualified Data.HashMap.Strict as HM
import GrimDawn.Aggregate (Location (..), OwnedItem (..))
import GrimDawn.Arz (Value (..))
import GrimDawn.Db (GameDb (..))
import GrimDawn.Formulas (craftableItems, scanRecordNames)
import GrimDawn.Gdc (itemBaseName)
import Test.Hspec

synthDb :: GameDb
synthDb =
  GameDb
    { gdbRecords =
        HM.fromList
          [ -- a blueprint: crafts the hood
            ( "records/items/crafting/blueprints/armor/bp_hood.dbr"
            , HM.fromList
                [ ("Class", VString "ItemArtifactFormula")
                , ("artifactName", VString "records/items/gearhead/d014_head.dbr")
                ]
            )
          , -- the crafted item
            ("records/items/gearhead/d014_head.dbr", HM.fromList [("Class", VString "ArmorProtective_Head")])
          , -- a plain item record (referenced directly, no artifactName)
            ("records/items/gearaccessories/rings/r001.dbr", HM.fromList [("Class", VString "ArmorJewelry_Ring")])
          ]
    , gdbText = HM.empty
    }

spec :: Spec
spec = describe "GrimDawn.Formulas" $ do
  it "scans embedded records/...dbr names, truncating at .dbr" $
    scanRecordNames "\x01\x02records/items/crafting/blueprints/armor/bp_hood.dbr\x00\xffrecords/items/gearhead/d014_head.dbrTRAILING"
      `shouldBe` [ "records/items/crafting/blueprints/armor/bp_hood.dbr"
                 , "records/items/gearhead/d014_head.dbr"
                 ]

  it "ignores text without a complete record name" $
    scanRecordNames "records/items/incomplete-no-extension and more" `shouldBe` []

  it "resolves a blueprint to the item it crafts (via artifactName)" $
    case craftableItems synthDb ["records/items/crafting/blueprints/armor/bp_hood.dbr"] of
      [oi] -> do
        itemBaseName (oiItem oi) `shouldBe` "records/items/gearhead/d014_head.dbr"
        oiLocation oi `shouldBe` Craftable
      other -> expectationFailure ("expected one craftable item, got " ++ show (length other))

  it "resolves a direct item record to itself, and drops unknown records" $ do
    let ois =
          craftableItems
            synthDb
            [ "records/items/gearaccessories/rings/r001.dbr"
            , "records/items/does/not/exist.dbr"
            ]
    map (itemBaseName . oiItem) ois `shouldBe` ["records/items/gearaccessories/rings/r001.dbr"]

  it "de-duplicates by basename (two blueprints crafting the same item)" $ do
    let ois = craftableItems synthDb (replicate 3 "records/items/crafting/blueprints/armor/bp_hood.dbr")
    length ois `shouldBe` 1
