-- | Command-line interface. One-shot subcommands:
--
-- > gd-explorer sets [--all] [--data-dir DIR]
-- > gd-explorer items [--type T] [--resist R]... [--damage D]... [--skill S]... [--set]
-- >                   [--char NAME] [--min-level N] [--max-level N] [--data-dir DIR]
-- > gd-explorer character [NAME] [--difficulty normal|elite|ultimate]
-- >                       [--overlay NAME]... [--buffs CATS] [--data-dir DIR]
-- > gd-explorer upgrades NAME [--slot SLOT] [--difficulty D] [--target N]
-- >                      [--max-level N] [--buffs CATS] [--weight CAT=FACTOR]... [--data-dir DIR]
-- > gd-explorer dps NAME [--buffs CATS] [--data-dir DIR]
module GrimDawn.Cli
  ( runCli
  , Command (..)
  , commandParser
  ) where

import Control.Monad (forM, forM_, unless)
import Data.Char (toLower)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr, stdout)

import Data.List (nubBy, sortOn)
import GrimDawn.Aggregate (OwnedItem (..), loadCharacters, loadOwnedItems, locationLabel)
import GrimDawn.Formulas (craftableItems, loadKnownFormulas)
import GrimDawn.Db (GameDb, loadGameDb)
import GrimDawn.Gdc (Character (..), Item)
import GrimDawn.Item (ItemAttrs (..), itemAttrs)
import GrimDawn.Report.Character (renderCharacter)
import GrimDawn.Report.Items
  ( ItemFilter (..)
  , emptyFilter
  , itemRows
  , matchesFilter
  , renderItems
  )
import GrimDawn.Report.Sets (renderSetReport, setReport)
import GrimDawn.Report.Stats
  ( BuffToggle
  , Difficulty (..)
  , Weights (..)
  , assumedBaseAttackSpeed
  , attackDps
  , defaultWeights
  , devotionSources
  , findUpgrades
  , masterySources
  , noBuffs
  , overlay
  , parseBuffs
  , parseDifficulty
  , plainSources
  , renderDps
  , renderStats
  , renderStatsDiff
  , renderUpgradeRow
  , setWeight
  , skillSources
  , statSources
  )

defaultDataDir :: FilePath
defaultDataDir = "data/gd-data"

-- | Parsed subcommand: @CmdSets dataDir showAll@ / @CmdItems dataDir filter@.
data Command
  = CmdSets FilePath Bool
  | CmdItems FilePath ItemFilter
  | CmdCharacter FilePath (Maybe Text) CharacterOpts
  | CmdUpgrades FilePath Text UpgradeOpts
  | CmdDps FilePath Text BuffToggle
  deriving (Show, Eq)

-- | Options for the @upgrades@ subcommand.
data UpgradeOpts = UpgradeOpts
  { uoSlot :: !Text
  , uoDifficulty :: !Difficulty
  , uoTarget :: !Double
  , uoMaxLevel :: !(Maybe Int)
  , uoBuffs :: !BuffToggle
  , uoWeights :: !Weights
  }
  deriving (Show, Eq)

-- | Options for the @character@ subcommand.
data CharacterOpts = CharacterOpts
  { coDifficulty :: !Difficulty -- resistance penalty tier
  , coOverlay :: ![Text] -- owned item names to overlay onto the build
  , coBuffs :: !BuffToggle -- which skill buff categories to fold in
  }
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
    <*> characterOptsParser

characterOptsParser :: Parser CharacterOpts
characterOptsParser =
  CharacterOpts
    <$> difficultyOpt
    <*> many
      (txtOption (long "overlay" <> metavar "NAME" <> help "Overlay an owned item by name onto the build; shows the stat diff (repeatable)"))
    <*> buffsOpt

buffsOpt :: Parser BuffToggle
buffsOpt =
  option
    (eitherReader parseBuffs)
    ( long "buffs"
        <> metavar "CATS"
        <> value noBuffs
        <> help "Fold in skill buffs: comma list of permanent,temporary,proc (or all/none)"
    )

difficultyOpt :: Parser Difficulty
difficultyOpt = difficultyOptWith Normal

difficultyOptWith :: Difficulty -> Parser Difficulty
difficultyOptWith def =
  option
    (eitherReader rd)
    ( long "difficulty"
        <> metavar "DIFF"
        <> value def
        <> showDefaultWith (map toLower . show)
        <> help "Resistance penalty tier for stats: normal | elite | ultimate"
    )
  where
    rd s = maybe (Left ("unknown difficulty: " ++ s)) Right (parseDifficulty s)

dpsParser :: Parser Command
dpsParser =
  CmdDps
    <$> dataDirOpt
    <*> (T.pack <$> argument str (metavar "NAME" <> help "Character to estimate attack DPS for"))
    <*> buffsOpt

upgradesParser :: Parser Command
upgradesParser =
  CmdUpgrades
    <$> dataDirOpt
    <*> (T.pack <$> argument str (metavar "NAME" <> help "Character to find upgrades for"))
    <*> upgradeOptsParser

upgradeOptsParser :: Parser UpgradeOpts
upgradeOptsParser =
  UpgradeOpts
    <$> (T.pack <$> strOption (long "slot" <> metavar "SLOT" <> value "boots" <> showDefault <> help "Item slot/type to search (e.g. boots, helm; ring1/ring2 for the two ring slots)"))
    <*> difficultyOptWith Ultimate
    <*> option auto (long "target" <> metavar "N" <> value 80 <> showDefault <> help "Resistance goal % for the non-linear resist weighting")
    <*> optional (option auto (long "max-level" <> metavar "N" <> help "Only consider items requiring level <= N"))
    <*> buffsOpt
    <*> weightsParser

weightsParser :: Parser Weights
weightsParser = foldl (\w (c, v) -> setWeight c v w) defaultWeights <$> many weightOpt
  where
    weightOpt =
      option
        (eitherReader rd)
        ( long "weight"
            <> metavar "CAT=FACTOR"
            <> help "Relative weight of a score component (repeatable): resist|oa|da|damage = number"
        )
    rd s = case break (== '=') s of
      (c, '=' : v)
        | c `elem` ["resist", "oa", "da", "damage"]
        , [(d, "")] <- reads v -> Right (T.pack c, d :: Double)
      _ -> Left ("expected CAT=FACTOR with CAT in resist|oa|da|damage: " ++ s)

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
        <> command "upgrades" (info upgradesParser (progDesc "Find owned items in a slot that improve a character"))
        <> command "dps" (info dpsParser (progDesc "Estimate per-hit and DPS of a character's attack skills"))
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
    craftable <- loadCraftable dir db
    TIO.putStr (renderSetReport showAll (setReport db (owned ++ craftable)))
  CmdItems dir flt -> do
    db <- loadGameDb dir >>= orDie
    owned <- loadOwnedItems dir >>= orDie
    craftable <- loadCraftable dir db
    let rows = itemRows db flt (owned ++ craftable)
    useColor <- hIsTerminalDevice stdout
    TIO.putStr (renderItems useColor rows)
    unless (null rows) $ TIO.putStrLn (T.pack (show (length rows)) <> " items")
  CmdCharacter dir mname copts -> do
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
            let base = charEquipped c
            found <-
              if null (coOverlay copts)
                then pure []
                else do
                  owned <- loadOwnedItems dir >>= orDie
                  fmap catMaybes . forM (coOverlay copts) $ \nm ->
                    case resolveOverlay db owned nm of
                      Just it -> pure (Just it)
                      Nothing -> do
                        hPutStrLn stderr ("warning: no owned item matching --overlay " ++ T.unpack nm)
                        pure Nothing
            let effective = overlay db base found
                -- non-skill sources (gear + devotions + mastery) drive both the
                -- base stats and the +skill levels used to scale skill buffs.
                nonSkill = statSources db effective ++ devotionSources db c ++ masterySources db c
                extra = devotionSources db c ++ masterySources db c ++ skillSources (coBuffs copts) nonSkill db c
            unless (null found) $ do
              TIO.putStrLn ""
              TIO.putStrLn ("Overlaying: " <> T.intercalate ", " (map (iaDisplayName . (`itemAttrs` db)) found))
              TIO.putStrLn ""
              TIO.putStr (renderStatsDiff useColor (coDifficulty copts) (plainSources extra) db base effective)
            TIO.putStrLn ""
            TIO.putStr (renderStats useColor (coDifficulty copts) c (plainSources extra) db effective)
  CmdUpgrades dir name uo -> do
    db <- loadGameDb dir >>= orDie
    chars <- loadCharacters dir >>= orDie
    owned <- loadOwnedItems dir >>= orDie
    case findChar name chars of
      Nothing -> do
        hPutStrLn stderr ("error: no character named " ++ T.unpack name)
        unless (null chars) $
          hPutStrLn stderr ("known: " ++ T.unpack (T.intercalate ", " (map charName chars)))
        exitFailure
      Just c -> do
        useColor <- hIsTerminalDevice stdout
        let base = charEquipped c
            nonSkill = statSources db base ++ devotionSources db c ++ masterySources db c
            extra = devotionSources db c ++ masterySources db c ++ skillSources (uoBuffs uo) nonSkill db c
            (slotName, slotOcc) = slotTarget (uoSlot uo)
            flt = emptyFilter {ifType = Just slotName, ifMaxLevel = uoMaxLevel uo}
            dn it = iaDisplayName (itemAttrs it db)
            candidates =
              nubBy (\a b -> dn (snd a) == dn (snd b))
                [(locationLabel (oiLocation oi), oiItem oi) | oi <- owned, matchesFilter flt (itemAttrs (oiItem oi) db) (oiLocation oi)]
            rows = take 3 (findUpgrades (uoWeights uo) (uoTarget uo) (uoDifficulty uo) slotOcc c extra db base candidates)
            w = uoWeights uo
        if null rows
          then TIO.putStrLn ("No " <> uoSlot uo <> " improve " <> charName c <> " with the given weights.")
          else do
            TIO.putStrLn
              ( "Top "
                  <> T.pack (show (length rows))
                  <> " "
                  <> uoSlot uo
                  <> " for "
                  <> charName c
                  <> " ("
                  <> T.pack (map toLower (show (uoDifficulty uo)))
                  <> "; weights resist="
                  <> wnum (wResist w)
                  <> " oa="
                  <> wnum (wOa w)
                  <> " da="
                  <> wnum (wDa w)
                  <> " damage="
                  <> wnum (wDamage w)
                  <> "):"
              )
            forM_ rows $ \r -> do
              TIO.putStrLn ""
              TIO.putStr (renderUpgradeRow useColor r)
  CmdDps dir name buffs -> do
    db <- loadGameDb dir >>= orDie
    chars <- loadCharacters dir >>= orDie
    case findChar name chars of
      Nothing -> do
        hPutStrLn stderr ("error: no character named " ++ T.unpack name)
        unless (null chars) $
          hPutStrLn stderr ("known: " ++ T.unpack (T.intercalate ", " (map charName chars)))
        exitFailure
      Just c -> do
        useColor <- hIsTerminalDevice stdout
        let base = charEquipped c
            nonSkill = statSources db base ++ devotionSources db c ++ masterySources db c
            extra = devotionSources db c ++ masterySources db c ++ skillSources buffs nonSkill db c
            sources = statSources db base ++ extra
            rows = attackDps db sources c
        if null rows
          then TIO.putStrLn ("No attack skills with estimable damage found for " <> charName c <> ".")
          else do
            TIO.putStrLn
              ( "Attack DPS estimate for "
                  <> charName c
                  <> "  (assumed base "
                  <> wnum assumedBaseAttackSpeed
                  <> " atk/s; conversions + stacking DoT applied; no crit or enemy resistance)"
              )
            TIO.putStrLn ""
            TIO.putStr (renderDps useColor rows)

-- | Load the items craftable from learned blueprints (@save/formulas.gst@),
-- as synthetic owned items. A missing file is silent; a parse error warns and
-- yields none, so the rest of the report is unaffected.
loadCraftable :: FilePath -> GameDb -> IO [OwnedItem]
loadCraftable dir db = do
  result <- loadKnownFormulas dir
  case result of
    Right names -> pure (craftableItems db names)
    Left err -> do
      hPutStrLn stderr ("warning: could not read formulas.gst: " ++ err)
      pure []

-- | Resolve a @--slot@ argument into the item type used for filtering candidates
-- and which equipped item of that type to replace (0-based). The two ring slots
-- are addressed as @ring1@/@ring2@ (bare @ring@ means the first); every other
-- slot maps to itself at occurrence 0.
slotTarget :: Text -> (Text, Int)
slotTarget s = case T.toLower s of
  "ring1" -> ("ring", 0)
  "ring2" -> ("ring", 1)
  _ -> (s, 0)

-- | Resolve an overlay item by display name among owned items (exact match
-- preferred, else first case-insensitive substring match).
resolveOverlay :: GameDb -> [OwnedItem] -> Text -> Maybe Item
resolveOverlay db owned name =
  case exact ++ partial of
    (it : _) -> Just it
    [] -> Nothing
  where
    target = T.toLower name
    dn oi = T.toLower (iaDisplayName (itemAttrs (oiItem oi) db))
    exact = [oiItem oi | oi <- owned, dn oi == target]
    partial = [oiItem oi | oi <- owned, target `T.isInfixOf` dn oi]

-- | Match a character by name, case-insensitively.
findChar :: Text -> [Character] -> Maybe Character
findChar name = go
  where
    target = T.toLower name
    go [] = Nothing
    go (c : cs) = if T.toLower (charName c) == target then Just c else go cs

-- | A non-negative number as text, dropping a trailing ".0".
wnum :: Double -> Text
wnum x =
  let r = round x :: Integer
   in if fromIntegral r == x then T.pack (show r) else T.pack (show x)

orDie :: Either String a -> IO a
orDie (Right x) = pure x
orDie (Left e) = hPutStrLn stderr ("error: " ++ e) >> exitFailure
