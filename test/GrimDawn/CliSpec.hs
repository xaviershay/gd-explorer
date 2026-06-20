module GrimDawn.CliSpec (spec) where

import GrimDawn.Cli (Command (..), commandParser)
import GrimDawn.Report.Items (ItemFilter (..), emptyFilter)
import Options.Applicative
import Test.Hspec

parse :: [String] -> Maybe Command
parse args =
  getParseResult $
    execParserPure defaultPrefs (info commandParser mempty) args

spec :: Spec
spec =
  describe "commandParser" $ do
    it "parses the sets subcommand with defaults" $
      parse ["sets"] `shouldBe` Just (CmdSets "data/gd-data" False)

    it "parses sets --all and --data-dir" $
      parse ["sets", "--all", "--data-dir", "/tmp/x"]
        `shouldBe` Just (CmdSets "/tmp/x" True)

    it "parses items with repeated --resist and level bounds" $
      parse
        [ "items"
        , "--type", "helm"
        , "--resist", "fire"
        , "--resist", "cold"
        , "--min-level", "50"
        , "--set"
        ]
        `shouldBe` Just
          ( CmdItems
              "data/gd-data"
              emptyFilter
                { ifType = Just "helm"
                , ifResists = ["fire", "cold"]
                , ifSetOnly = True
                , ifMinLevel = Just 50
                }
          )

    it "rejects an unknown subcommand" $
      parse ["bogus"] `shouldBe` Nothing
