module Main (main) where

import Data.List (sortOn, minimumBy)
import Data.Ord (comparing)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import GrimDawn.Db (GameDb)
import GrimDawn.Gdc (Character, charName)
import OaDaFit.Csv (Obs (..), parseDataCsv)
import OaDaFit.Inputs (Inputs (..), characterHealth, characterInputs, loadInputs)
import OaDaFit.Model

main :: IO ()
main = do
  raw <- TIO.readFile "data.csv"
  let obs = parseDataCsv raw
  (db, chars) <- loadInputs "data/gd-data"
  let resolved = map (resolveObs db chars) obs
      unmatched = [o | (o, Nothing) <- resolved]
  if not (null unmatched)
    then do
      hPutStrLn stderr "ERROR: the following data.csv rows matched no loaded character:"
      mapM_ (hPutStrLn stderr . ("  " ++) . T.unpack . obsName) unmatched
      exitFailure
    else do
      let pairs = [(o, c) | (o, Just c) <- resolved]
          points ab =
            [ Point inp (if ab == OA then obsOA o else obsDA o)
            | (o, c) <- pairs
            , let inp = characterInputs db c (obsGear o)
            ]
      putStrLn "=== Offensive Ability ==="
      report OA (points OA)
      putStrLn ""
      putStrLn "=== Defensive Ability ==="
      report DA (points DA)

-- | Resolve one data.csv row to the character it was observed on. Matching is
-- case-insensitive on name. Duplicate saves sharing a name are disambiguated
-- by picking the one whose computed Health (in the same gear state as the
-- row) is closest to the observed Health.
resolveObs :: GameDb -> [Character] -> Obs -> (Obs, Maybe Character)
resolveObs db chars o = (o, pick matches)
  where
    lname = T.toLower (obsName o)
    matches = [c | c <- chars, T.toLower (charName c) == lname]
    pick [] = Nothing
    pick [c] = Just c
    pick cs =
      Just $
        minimumBy
          (comparing (\c -> abs (characterHealth db c (obsGear o) - obsHealth o)))
          cs

report :: Ability -> [Point] -> IO ()
report ab pts = do
  let fitted =
        [ (cName c, fr)
        | c <- candidates
        , Just fr <- [fitCandidate ab pts c]
        ]
      ranked = sortOn (frLooRms . snd) fitted
  mapM_ line ranked
  case ranked of
    ((nm, fr) : _) -> do
      putStrLn ""
      printf "  BEST: %s\n" nm
      printf "    predicted = (%.3f + %.4f*level + %.4f*attr + %.4f*masteryRanks + flat) * (1 + pct/100)\n"
        (frBase fr) (frLevel fr) (frAttr fr) (frMastery fr)
      putStrLn "  Per-point predicted vs observed:"
      mapM_ (perPoint ab fr) pts
    [] -> putStrLn "  (no candidate fit)"
  where
    line (nm, fr) =
      printf "  %-32s  RMS %8.2f  maxAbs %8.2f  LOO-RMS %8.2f   [base %.2f, lvl %.4f, attr %.4f, mast %.4f]\n"
        nm (frRms fr) (frMaxAbs fr) (frLooRms fr)
        (frBase fr) (frLevel fr) (frAttr fr) (frMastery fr)
    perPoint a fr p =
      let i = pInputs p
          pr = predict a fr i
       in printf "    %-12s %-8s  pred %8.1f  obs %8.1f  resid %+7.1f\n"
            (T.unpack (inName i))
            (if inGeared i then "geared" else "ungeared" :: String)
            pr (pObserved p) (pr - pObserved p)
