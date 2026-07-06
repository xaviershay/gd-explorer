module OaDaFit.GoldenSpec (spec) where

import Control.Monad (unless)
import System.Directory (doesFileExist)
import Test.Hspec
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GrimDawn.Db (GameDb)
import GrimDawn.Gdc (Character (..))
import GrimDawn.Report.Stats (statSummary, Difficulty (..), StatSummary (..))
import OaDaFit.Csv (Obs (..), parseDataCsv)
import OaDaFit.Inputs (loadInputs, characterHealth, characterSources)
import OaDaFit.Resolve (resolveMatch)

-- Coarse regression guard, not a precision bound: the fit's max per-character
-- residual is ~134 for OA (typical error ~30-50). The OLD (pre-fit) formula
-- misses ground truth by many hundreds to 1000+, so tol=140 still firmly
-- distinguishes a correct formula from the old guessed one.
tol :: Double
tol = 140

spec :: Spec
spec = describe "shipped OA/DA formula vs ground truth (data.csv)" $
  it "matches every resolved character/gear-state row within tol" $ do
    present <- doesFileExist "data.csv"
    if not present
      then pendingWith "data.csv not present — skipping OA/DA golden regression"
      else do
        raw <- TIO.readFile "data.csv"
        (db, chars) <- loadInputs "data/gd-data"
        let rows = parseDataCsv raw
        mapM_ (checkRow db chars) rows

checkRow :: GameDb -> [Character] -> Obs -> IO ()
checkRow db chars o =
  case resolveMatch charName (\c -> characterHealth db c (obsGear o)) (obsName o) (obsHealth o) chars of
    Nothing -> expectationFailure ("no character resolved for row: " ++ T.unpack (obsName o))
    Just c -> do
      let src = characterSources db c (obsGear o)
          s = statSummary Normal c src
          oa = ssOaTotal s
          da = ssDaTotal s
          label = T.unpack (charName c) ++ " (gear=" ++ show (obsGear o) ++ ")"
      unless (abs (oa - obsOA o) <= tol) $
        expectationFailure $
          "OA mismatch for " ++ label
            ++ ": computed=" ++ show oa
            ++ " observed=" ++ show (obsOA o)
      unless (abs (da - obsDA o) <= tol) $
        expectationFailure $
          "DA mismatch for " ++ label
            ++ ": computed=" ++ show da
            ++ " observed=" ++ show (obsDA o)
