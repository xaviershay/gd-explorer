-- | Set-completion report: for every item set in the database, show which
-- member items are owned (across all characters + the shared stash) and which
-- are missing.
--
-- Set schema (confirmed against real data): set records carry a @setMembers@
-- list of member item record names and a @setName@ display name. We treat a set
-- member as owned when any aggregated item's basename matches it.
module GrimDawn.Report.Sets
  ( SetMember (..)
  , smCount
  , smOwned
  , SetCompletion (..)
  , scOwnedCount
  , scTotal
  , scComplete
  , discoverSets
  , setMemberNames
  , setReport
  , renderSetReport
  ) where

import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import GrimDawn.Aggregate (OwnedItem (..), locationLabel)
import GrimDawn.Arz (Record, Value (..), lookupField, valueText)
import GrimDawn.Db (GameDb (..), lookupRecord)
import GrimDawn.Gdc (itemBaseName)

data SetMember = SetMember
  { smRecord :: !Text
  , smName :: !Text
  , -- | Where the owned copies of this piece live: @(location, count)@,
    -- empty when the piece is missing.
    smHoldings :: ![(Text, Int)]
  }
  deriving (Show, Eq)

-- | Total number of copies of this piece owned across all locations.
smCount :: SetMember -> Int
smCount = sum . map snd . smHoldings

-- | Whether at least one copy of this piece is owned.
smOwned :: SetMember -> Bool
smOwned = not . null . smHoldings

data SetCompletion = SetCompletion
  { scRecord :: !Text
  , scName :: !Text
  , scMembers :: ![SetMember]
  }
  deriving (Show, Eq)

-- | Number of distinct member pieces owned (not counting duplicates).
scOwnedCount :: SetCompletion -> Int
scOwnedCount = length . filter smOwned . scMembers

scTotal :: SetCompletion -> Int
scTotal = length . scMembers

scComplete :: SetCompletion -> Bool
scComplete sc = scTotal sc > 0 && scOwnedCount sc == scTotal sc

-- | All set definition records: those carrying a @setMembers@ field.
discoverSets :: GameDb -> [(Text, Record)]
discoverSets db =
  [ (name, r)
  | (name, r) <- HM.toList (gdbRecords db)
  , HM.member "setMembers" r
  ]

-- | Member item record names declared by a set record.
setMemberNames :: Record -> [Text]
setMemberNames r =
  case lookupField "setMembers" r of
    Just (VList vs) -> [s | VString s <- vs]
    Just (VString s) -> [s]
    _ -> []

-- display name for a member item record (itemNameTag, fallback to record path)
memberDisplayName :: GameDb -> Text -> Text
memberDisplayName db rn =
  case lookupRecord rn db >>= lookupField "itemNameTag" >>= valueText of
    Just n -> n
    Nothing -> rn

setName :: Text -> Record -> Text
setName fallback r =
  case lookupField "setName" r >>= valueText of
    Just n -> n
    Nothing -> fallback

-- | Build the completion report for every set, given all owned items.
setReport :: GameDb -> [OwnedItem] -> [SetCompletion]
setReport db owned =
  sortOn scName (map toCompletion (discoverSets db))
  where
    -- basename -> location label -> count of owned copies
    holdingsByBasename :: HashMap Text (HashMap Text Int)
    holdingsByBasename =
      HM.fromListWith
        (HM.unionWith (+))
        [ (itemBaseName (oiItem oi), HM.singleton (locationLabel (oiLocation oi)) 1)
        | oi <- owned
        ]

    memberHoldings :: Text -> [(Text, Int)]
    memberHoldings m =
      sortOn fst (HM.toList (HM.lookupDefault HM.empty m holdingsByBasename))

    toCompletion (rn, r) =
      SetCompletion
        { scRecord = rn
        , scName = setName rn r
        , scMembers =
            [ SetMember
                { smRecord = m
                , smName = memberDisplayName db m
                , smHoldings = memberHoldings m
                }
            | m <- setMemberNames r
            ]
        }

-- | Render the report as plain text. Only sets with at least one owned piece
-- are shown; for each set, every member is listed with how many are owned and
-- where. With @showComplete@ False, fully-owned sets are omitted.
renderSetReport :: Bool -> [SetCompletion] -> Text
renderSetReport showComplete sets =
  T.unlines (concatMap renderOne (filter relevant sets))
  where
    relevant sc =
      scOwnedCount sc > 0 && (showComplete || not (scComplete sc))

    renderOne sc = header : map renderMember (scMembers sc)
      where
        header =
          scName sc
            <> "  "
            <> T.pack (show (scOwnedCount sc))
            <> "/"
            <> T.pack (show (scTotal sc))
            <> (if scComplete sc then "  COMPLETE" else "")

    renderMember m
      | smOwned m =
          "    " <> smName m <> "  x" <> T.pack (show (smCount m))
            <> "  (" <> renderHoldings (smHoldings m) <> ")"
      | otherwise = "    " <> smName m <> "  missing"

    renderHoldings = T.intercalate ", " . map renderHolding
    renderHolding (loc, n)
      | n <= 1 = loc
      | otherwise = loc <> " x" <> T.pack (show n)
