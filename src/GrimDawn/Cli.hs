-- | Command-line interface. One-shot subcommands:
--
-- > gd-explorer sets [--all] [--data-dir DIR]
-- > gd-explorer items [--type T] [--resist R]... [--damage D]... [--skill S]... [--set]
-- >                   [--char NAME] [--min-level N] [--max-level N] [--data-dir DIR]
-- > gd-explorer character [NAME] [--data-dir DIR]
module GrimDawn.Cli
  ( runCli
  , Command (..)
  , commandParser
  ) where

import Control.Monad (unless)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr, stdout)

import Data.List (sortOn)
import GrimDawn.Aggregate (loadCharacters, loadOwnedItems)
import GrimDawn.Db (loadGameDb)
import GrimDawn.Gdc (Character (..))
import GrimDawn.Report.Character (renderCharacter)
import GrimDawn.Report.Items
  ( ItemFilter (..)
  , itemRows
  , renderItems
  )
import GrimDawn.Report.Sets (renderSetReport, setReport)

defaultDataDir :: FilePath
defaultDataDir = "data/gd-data"

-- | Parsed subcommand: @CmdSets dataDir showAll@ / @CmdItems dataDir filter@.
data Command
  = CmdSets FilePath Bool
  | CmdItems FilePath ItemFilter
  | CmdCharacter FilePath (Maybe Text)
  deriving (Show, Eq)

dataDirOpt :: Parser FilePath
dataDirOpt =
  strOption
    ( long "data-dir"
        <> metavar "DIR"
        <> value defaultDataDir
        <> showDefault
        <> help "Root directory holding game/ and save/"
    )

setsParser :: Parser Command
setsParser =
  CmdSets
    <$> dataDirOpt
    <*> switch (long "all" <> help "Show completed sets too, not just incomplete")

itemsParser :: Parser Command
itemsParser =
  CmdItems
    <$> dataDirOpt
    <*> filterParser

characterParser :: Parser Command
characterParser =
  CmdCharacter
    <$> dataDirOpt
    <*> optional (T.pack <$> argument str (metavar "NAME" <> help "Character name (omit to list characters)"))

filterParser :: Parser ItemFilter
filterParser =
  ItemFilter
    <$> optional
      (strOption (long "type" <> metavar "TYPE" <> help "Item type/slot (e.g. helm, ring, sword)"))
    <*> many
      (txtOption (long "resist" <> metavar "RES" <> help "Require a resistance (repeatable)"))
    <*> many
      (txtOption (long "damage" <> metavar "DMG" <> help "Require a damage type (repeatable)"))
    <*> many
      (txtOption (long "skill" <> metavar "SKILL" <> help "Require a +skill bonus matching SKILL substring; use \"\" for any (repeatable)"))
    <*> switch (long "set" <> help "Only set items")
    <*> optional
      (txtOption (long "char" <> metavar "NAME" <> help "Restrict to a character"))
    <*> optional (option auto (long "min-level" <> metavar "N" <> help "Minimum level requirement"))
    <*> optional (option auto (long "max-level" <> metavar "N" <> help "Maximum level requirement"))

txtOption :: Mod OptionFields String -> Parser Text
txtOption = fmap T.pack . strOption

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "sets" (info setsParser (progDesc "Set-completion report"))
        <> command "items" (info itemsParser (progDesc "Filterable item inventory"))
        <> command "character" (info characterParser (progDesc "A character's gear, skills, and devotions"))
    )

opts :: ParserInfo Command
opts =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> header "gd-explorer - explore Grim Dawn save data"
        <> progDesc "Report on owned items and set completion"
    )

runCli :: IO ()
runCli = execParser opts >>= run

run :: Command -> IO ()
run = \case
  CmdSets dir showAll -> do
    db <- loadGameDb dir >>= orDie
    owned <- loadOwnedItems dir >>= orDie
    TIO.putStr (renderSetReport showAll (setReport db owned))
  CmdItems dir flt -> do
    db <- loadGameDb dir >>= orDie
    owned <- loadOwnedItems dir >>= orDie
    let rows = itemRows db flt owned
    useColor <- hIsTerminalDevice stdout
    TIO.putStr (renderItems useColor rows)
    unless (null rows) $ TIO.putStrLn (T.pack (show (length rows)) <> " items")
  CmdCharacter dir mname -> do
    chars <- loadCharacters dir >>= orDie
    case mname of
      Nothing -> do
        let names = sortOn T.toLower (map charName chars)
        TIO.putStr (T.unlines names)
      Just name ->
        case findChar name chars of
          Nothing -> do
            hPutStrLn stderr ("error: no character named " ++ T.unpack name)
            unless (null chars) $
              hPutStrLn stderr ("known: " ++ T.unpack (T.intercalate ", " (map charName chars)))
            exitFailure
          Just c -> do
            db <- loadGameDb dir >>= orDie
            useColor <- hIsTerminalDevice stdout
            TIO.putStr (renderCharacter useColor db c)

-- | Match a character by name, case-insensitively.
findChar :: Text -> [Character] -> Maybe Character
findChar name = go
  where
    target = T.toLower name
    go [] = Nothing
    go (c : cs) = if T.toLower (charName c) == target then Just c else go cs

orDie :: Either String a -> IO a
orDie (Right x) = pure x
orDie (Left e) = hPutStrLn stderr ("error: " ++ e) >> exitFailure
