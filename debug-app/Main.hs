module Main (main) where

import Data.List (find, sortOn)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Text.Printf (printf)
import GrimDawn.Gdc (charName)
import OaDaFit.Csv (Obs (..), parseDataCsv)
import OaDaFit.Inputs (Inputs (..), characterInputs, loadInputs)
import OaDaFit.Model

main :: IO ()
main = do
  raw <- TIO.readFile "data.csv"
  let obs = parseDataCsv raw
  (db, chars) <- loadInputs "data/gd-data"
  let points ab =
        [ Point inp (if ab == OA then obsOA o else obsDA o)
        | o <- obs
        , Just c <- [find ((== obsName o) . charName) chars]
        , let inp = characterInputs db c (obsGear o)
        ]
  putStrLn "=== Offensive Ability ==="
  report OA (points OA)
  putStrLn ""
  putStrLn "=== Defensive Ability ==="
  report DA (points DA)

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
      printf "  %-32s  RMS %8.2f  maxAbs %8.2f  LOO-RMS %8.2f\n"
        nm (frRms fr) (frMaxAbs fr) (frLooRms fr)
    perPoint a fr p =
      let i = pInputs p
          pr = predict a fr i
       in printf "    %-12s %-8s  pred %8.1f  obs %8.1f  resid %+7.1f\n"
            (T.unpack (inName i))
            (if inGeared i then "geared" else "ungeared" :: String)
            pr (pObserved p) (pr - pObserved p)
