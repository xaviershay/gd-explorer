{-# LANGUAGE OverloadedStrings #-}

-- | A small local HTTP server (scotty + warp) for the web UI. The expensive game
-- database is loaded once at startup and held resident; the tiny save data
-- (characters + owned items) is re-read per request so the UI always reflects the
-- latest play session without a restart. JSON endpoints feed the React frontend,
-- whose built assets are served as static files.
module GrimDawn.Web.Server
  ( ServeOpts (..)
  , runServer
  , textureKey
  ) where

import Control.Monad (filterM, forM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find, nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Network.HTTP.Types (status200, status404, status500)
import Network.Wai (Application, Middleware, pathInfo, queryString, responseFile, responseLBS)
import qualified Data.Text.Encoding as TE
import Text.Read (readMaybe)
import Network.Wai.Application.Static (defaultWebAppSettings, staticApp)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import Web.Scotty
import WaiAppStatic.Types (ss404Handler, ssIndices, unsafeToPiece)

import GrimDawn.Aggregate (OwnedItem (..), loadCharacters, loadOwnedItems)
import GrimDawn.Arc (loadArchiveFile)
import GrimDawn.Db (GameDb, loadGameDb)
import GrimDawn.Formulas (craftableItems, loadKnownFormulas)
import GrimDawn.Gdc (Character (..), itemBaseName, itemWithName)
import GrimDawn.Item (iaBitmap, itemAttrs)
import GrimDawn.Report.Stats (AttackKind (..), Difficulty (..), parseDifficulty)
import GrimDawn.Web.Texture (decodeTexture)
import GrimDawn.Web.View (GearOverride (..), attackBreakdownView, craftableBlueprints, detailView, enhancementCatalog, rankEnhancements, rankItems, setsView, skillDictionary, summaryView)

data ServeOpts = ServeOpts
  { soPort :: !Int
  , soDataDir :: !FilePath -- root holding game/ and save/
  , soStaticDir :: !FilePath -- built frontend (frontend/dist)
  }
  deriving (Show, Eq)

-- | Asset-archive entries (texture path -> raw bytes), lazily loaded on first
-- image request and cached. Keys are lowercased for case-insensitive lookup.
type Textures = HashMap Text BS.ByteString

-- | Load the game database once, then serve the API + static frontend.
runServer :: ServeOpts -> IO ()
runServer opts = do
  hPutStrLn stderr "Loading game database (this takes a few seconds)..."
  dbE <- loadGameDb (soDataDir opts)
  case dbE of
    Left e -> hPutStrLn stderr ("error: " ++ e) >> exitFailure
    Right db -> do
      haveStatic <- doesDirectoryExist (soStaticDir opts)
      if haveStatic
        then hPutStrLn stderr ("Serving frontend from " ++ soStaticDir opts)
        else hPutStrLn stderr ("note: no frontend build at " ++ soStaticDir opts ++ " (API only); run `npm --prefix frontend run build`")
      texCache <- newIORef Nothing
      hPutStrLn stderr ("Listening on http://localhost:" ++ show (soPort opts))
      scotty (soPort opts) (routes db texCache opts)

routes :: GameDb -> IORef (Maybe Textures) -> ServeOpts -> ScottyM ()
routes db texCache opts = do
  middleware (staticMiddleware (soStaticDir opts))
  -- Built once and shared (forced on first request) — it scans the whole DB.
  let skillDict = skillDictionary db

  get "/api/sets" $ do
    owned <- loadOr (loadOwnedItems (soDataDir opts))
    -- Learned blueprints are optional; a missing/unreadable formulas.gst just
    -- means "nothing craftable", so never fail the sets page over it.
    craftable <- liftIO (either (const []) (craftableItems db) <$> loadKnownFormulas (soDataDir opts))
    let craftableNames = map (itemBaseName . oiItem) craftable
    json (setsView db craftableNames owned)

  get "/api/characters" $ do
    chars <- loadOr (loadCharacters (soDataDir opts))
    json (map (summaryView db) chars)

  -- The attachable components/augments, for the gear configuration selectors.
  get "/api/enhancements" $ json (enhancementCatalog db)

  -- Skill display name -> description, for tooltips on "Grants X" / "+N X" lines.
  -- Computed once (lazily) and shared across requests.
  get "/api/skills" $ json skillDict

  -- Component / relic blueprint collections: every craftable item flagged by
  -- blueprint status (learned/default/missing). Missing/unreadable formulas.gst
  -- just means nothing learned.
  -- The blacksmith crafts low-level recipes for free (no blueprint): components
  -- up to level 20, relics up to level 24.
  get "/api/components" $ do
    learned <- liftIO (either (const []) id <$> loadKnownFormulas (soDataDir opts))
    json (craftableBlueprints "ItemRelic" 20 db learned)

  get "/api/relics" $ do
    learned <- liftIO (either (const []) id <$> loadKnownFormulas (soDataDir opts))
    json (craftableBlueprints "ItemArtifact" 24 db learned)

  get "/api/characters/:name" $ do
    name <- pathParam "name"
    overrides <- parseOverrides . queryString <$> request
    diff <- difficultyParam
    chars <- loadOr (loadCharacters (soDataDir opts))
    owned <- loadOr (loadOwnedItems (soDataDir opts))
    case findChar name chars of
      Just c -> json (detailView db owned overrides diff c)
      Nothing -> do
        status status404
        text ("no character named " <> TL.fromStrict name)

  -- Rank components/augments compatible with a gear slot by the same scoring
  -- algorithm as the `upgrades` CLI, holding the rest of the (override-adjusted)
  -- build constant. Returns record names in best-first order. Fetched on demand
  -- by the picker UI to sort options.
  get "/api/characters/:name/rank" $ do
    name <- pathParam "name"
    slot <- queryParam "slot"
    kind <- queryParam "kind"
    overrides <- parseOverrides . queryString <$> request
    diff <- difficultyParam
    chars <- loadOr (loadCharacters (soDataDir opts))
    case findChar name chars of
      Just c -> json (rankEnhancements db overrides diff slot kind c)
      Nothing -> do
        status status404
        text ("no character named " <> TL.fromStrict name)

  -- Alternate items for a gear slot, scored by the `upgrades` path (the
  -- candidate inherits the slot's component/augment). Best-first, only items that
  -- improve on the current one; each carries its location (character/stash, or
  -- "craftable (blueprint)" for an unowned item with a learned blueprint). Owned
  -- items are listed first so a duplicate display name prefers the owned copy.
  get "/api/characters/:name/items" $ do
    name <- pathParam "name"
    slot <- queryParam "slot"
    overrides <- parseOverrides . queryString <$> request
    diff <- difficultyParam
    chars <- loadOr (loadCharacters (soDataDir opts))
    owned <- loadOr (loadOwnedItems (soDataDir opts))
    -- Learned blueprints are optional; a missing/unreadable formulas.gst just
    -- means "nothing craftable", so never fail the picker over it.
    craftable <- liftIO (either (const []) (craftableItems db) <$> loadKnownFormulas (soDataDir opts))
    case findChar name chars of
      Just c -> json (rankItems db (owned ++ craftable) overrides diff slot c)
      Nothing -> do
        status status404
        text ("no character named " <> TL.fromStrict name)

  -- The DPS attribution breakdown for one attack/proc row: which sources
  -- contribute how much flat damage and how many percentage points, a
  -- retaliation-added-to-attack chain, rate factors, and a DPS-impact
  -- ranking. Identified by name + optional rank + kind, matching a row
  -- already returned by /api/characters/:name.
  get "/api/characters/:name/attack-breakdown" $ do
    name <- pathParam "name"
    attackName <- queryParam "attack"
    rank <- (readMaybe . T.unpack =<<) <$> queryParamMaybe "rank"
    kindParam <- queryParam "kind"
    let kind = if (kindParam :: Text) == "proc" then Triggered else Active
    overrides <- parseOverrides . queryString <$> request
    diff <- difficultyParam
    chars <- loadOr (loadCharacters (soDataDir opts))
    owned <- loadOr (loadOwnedItems (soDataDir opts))
    case findChar name chars of
      Nothing -> do
        status status404
        text ("no character named " <> TL.fromStrict name)
      Just c -> case attackBreakdownView db owned overrides diff c attackName rank kind of
        Just abv -> json abv
        Nothing -> do
          status status404
          text "no matching attack/proc row"

  -- An item's icon, decoded from the asset archive's .tex to PNG. 404s cleanly
  -- when the texture archive isn't synced or the icon can't be decoded, so the
  -- frontend falls back to a placeholder.
  get "/api/item-image/:record" $ do
    rec <- pathParam "record"
    case iaBitmap (itemAttrs (itemWithName rec) db) of
      Nothing -> status status404 >> text "no bitmap for item"
      Just path -> do
        tex <- liftIO (getTextures texCache opts)
        case HM.lookup (textureKey path) tex >>= decodeTexture of
          Just png -> do
            setHeader "Content-Type" "image/png"
            setHeader "Cache-Control" "max-age=86400"
            raw (BL.fromStrict png)
          Nothing -> status status404 >> text "texture unavailable"

-- | Run an @Either@-returning loader, turning a @Left@ into a 500 response.
loadOr :: IO (Either String a) -> ActionM a
loadOr act = do
  r <- liftIO act
  case r of
    Right x -> pure x
    Left e -> do
      status status500
      text (TL.pack ("error: " ++ e))
      finish

-- | Match a character by name, case-insensitively (mirrors @Cli.findChar@).
findChar :: Text -> [Character] -> Maybe Character
findChar name = find ((== T.toLower name) . T.toLower . charName)

-- | Parse @item.<i>@ / @comp.<i>@ / @aug.<i>@ query params into per-slot gear
-- overrides. @item@ swaps the slot's base item (inheriting its component/augment);
-- @comp@/@aug@ swap the attachment. A value of @none@ clears it; any other value
-- sets that record; an absent param leaves the slot's original in place.
parseOverrides :: [(BS.ByteString, Maybe BS.ByteString)] -> [GearOverride]
parseOverrides qs =
  [ GearOverride i (lookup i items) (lookup i comps) (lookup i augs)
  | i <- nub (map fst items ++ map fst comps ++ map fst augs)
  ]
  where
    decoded = [(TE.decodeUtf8 k, maybe "" TE.decodeUtf8 v) | (k, v) <- qs]
    pick pre =
      [ (i, if v == "none" then "" else v)
      | (k, v) <- decoded
      , Just rest <- [T.stripPrefix pre k]
      , Just i <- [readMaybe (T.unpack rest)]
      ]
    items = pick "item."
    comps = pick "comp."
    augs = pick "aug."

-- | The optional @?difficulty=normal|elite|ultimate@ query parameter, defaulting
-- to Ultimate (the canonical end-game view used by the @character@ CLI report).
difficultyParam :: ActionM Difficulty
difficultyParam = do
  qs <- queryString <$> request
  pure $ case lookup "difficulty" qs of
    Just (Just v) -> fromMaybe Ultimate (parseDifficulty (T.unpack (TE.decodeUtf8 v)))
    _ -> Ultimate

-- | Normalise an item's @bitmap@ path to its archive key. Records reference
-- textures as @items/<...>.tex@, but @Items.arc@ stores them without the leading
-- @items/@ segment; keys are lowercased for case-insensitive lookup.
textureKey :: Text -> Text
textureKey path = let p = T.toLower path in maybe p id (T.stripPrefix "items/" p)

-- | Texture archive entries, loaded+merged on first use and cached. Empty (so
-- every image 404s) when no asset archive is present under the data dir.
getTextures :: IORef (Maybe Textures) -> ServeOpts -> IO Textures
getTextures cache opts = do
  cached <- readIORef cache
  case cached of
    Just t -> pure t
    Nothing -> do
      t <- loadTextures opts
      writeIORef cache (Just t)
      pure t

loadTextures :: ServeOpts -> IO Textures
loadTextures opts = do
  let candidates =
        [ soDataDir opts </> "game" </> rel
        | rel <-
            [ "resources/Items.arc"
            , "gdx1/resources/Items.arc"
            , "gdx2/resources/Items.arc"
            , "gdx3/resources/Items.arc"
            ]
        ]
  present <- filterM doesFileExist candidates
  maps <- forM present $ \fp -> do
    r <- loadArchiveFile fp
    case r of
      Left e -> hPutStrLn stderr ("warning: " ++ fp ++ ": " ++ e) >> pure HM.empty
      Right m -> pure (HM.fromList [(T.toLower k, v) | (k, v) <- HM.toList m])
  pure (HM.unions maps)

-- | Serve the built frontend for non-API requests, falling back to index.html so
-- client-side routes deep-link correctly. API requests pass through to scotty.
staticMiddleware :: FilePath -> Middleware
staticMiddleware dir inner req respond
  | isApi = inner req respond
  | otherwise = staticApp settings req respond
  where
    isApi = case pathInfo req of
      ("api" : _) -> True
      _ -> False
    settings =
      (defaultWebAppSettings dir)
        { ssIndices = [unsafeToPiece "index.html"]
        , ss404Handler = Just (indexFallback dir)
        }

-- | Serve index.html (HTTP 200) so a single-page app's routes resolve; if it is
-- missing (no build yet), return a plain 404.
indexFallback :: FilePath -> Application
indexFallback dir _req respond = do
  let index = dir </> "index.html"
  present <- doesFileExist index
  respond $
    if present
      then responseFile status200 [("Content-Type", "text/html")] index Nothing
      else responseLBS status404 [("Content-Type", "text/plain")] "not found"
