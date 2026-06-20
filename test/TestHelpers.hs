-- | Shared helpers for tests that depend on the real Grim Dawn data set under
-- @data/gd-data@. When the data is absent (fresh clone / CI), the dependent
-- example is marked pending rather than failing.
module TestHelpers
  ( dataDir
  , gamePath
  , savePath
  , transferStashPath
  , withDataFile
  ) where

import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec (Expectation, pendingWith)

-- | Root of the local data set. Override with the @GD_DATA_DIR@ env var if
-- your layout differs.
dataDir :: FilePath
dataDir = "data/gd-data"

gamePath :: FilePath -> FilePath
gamePath rel = dataDir </> "game" </> rel

savePath :: FilePath -> FilePath
savePath rel = dataDir </> "save" </> rel

transferStashPath :: FilePath
transferStashPath = savePath "transfer.gst"

-- | Run an expectation that needs a data file, skipping (pending) if missing.
withDataFile :: FilePath -> (FilePath -> Expectation) -> Expectation
withDataFile fp act = do
  ok <- doesFileExist fp
  if ok then act fp else pendingWith ("missing data file: " ++ fp)
