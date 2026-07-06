module Main (main) where

import qualified Data.Text.IO as TIO
import OaDaFit.Csv (parseDataCsv)

main :: IO ()
main = do
  raw <- TIO.readFile "data.csv"
  mapM_ (putStrLn . show) (parseDataCsv raw)
