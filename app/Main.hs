module Main (main) where

import Options.Applicative
import System.Environment (getArgs, withArgs)

import GrimDawn.Cli (runCli)
import GrimDawn.Web.Server (ServeOpts (..), runServer)

-- | @serve@ launches the local web UI server; every other command is handled by
-- the existing CLI. Dispatching here keeps the warp/scotty dependencies in the
-- executable, out of the core library and test build.
main :: IO ()
main = do
  args <- getArgs
  case args of
    ("serve" : rest) -> withArgs rest serveMain
    _ -> runCli

serveMain :: IO ()
serveMain = runServer =<< execParser p
  where
    p =
      info
        (serveOpts <**> helper)
        (fullDesc <> progDesc "Run the local web UI server (loads the game DB once and serves it)")

serveOpts :: Parser ServeOpts
serveOpts =
  ServeOpts
    <$> option
      auto
      (long "port" <> metavar "PORT" <> value 8080 <> showDefault <> help "Port to listen on")
    <*> strOption
      (long "data-dir" <> metavar "DIR" <> value "data/gd-data" <> showDefault <> help "Root directory holding game/ and save/")
    <*> strOption
      (long "static" <> metavar "DIR" <> value "frontend/dist" <> showDefault <> help "Built frontend directory to serve")
