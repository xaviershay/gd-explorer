# DPS Attribution Breakdown — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `GET /api/characters/:name/attack-breakdown` endpoint that, for one selected attack/proc row, returns a full source-attributed breakdown: which gear/component/augment/devotion/mastery/skill contributed how much flat damage and how many percentage points per damage type, a dedicated retaliation-added-to-attack chain, attack-speed/cooldown-reduction/weapon-damage% rate factors, and a DPS-impact ranking per source.

**Architecture:** Every stat-contributing record already collected by `GrimDawn.Report.Stats` (`statSources`, `devotionSources`, `masterySources`, `skillSources`) gets tagged with an owning `Source` (display label + category) instead of a bare record-path `Text`. `attackDps`'s internal per-type damage computation (`typedDamage`) is rewritten to build a per-source breakdown as its primary computation, with the existing aggregate `AttackDps` output derived by summing it — so the summary panel and the new breakdown can never disagree. A new `attackDpsBreakdown` function picks one row out of that same computation and also computes each source's DPS impact by re-running the computation with that source excluded. `GrimDawn.Web.View` and `GrimDawn.Web.Server` expose it as JSON.

**Tech Stack:** Haskell (GHC via `stack build`/`stack test`, hspec), Scotty (existing web server).

This plan only covers the backend. A follow-up plan (`docs/superpowers/plans/2026-07-03-dps-attribution-breakdown-frontend.md`) covers the React page that consumes this endpoint; it depends on this plan being complete first (it needs the real JSON shape to build against).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-03-dps-attribution-breakdown-design.md`. Every field name, formula, and JSON shape below follows that spec (with the `Source` threading implemented more narrowly than the spec's rough estimate — see Task 1 note).
- `attackDps`'s existing exported behavior (its `[AttackDps]` output — the numbers already shown in the "Attack DPS estimate" panel) must not change. Every existing test in `test/GrimDawn/Report/StatsSpec.hs` must keep passing with identical assertions (only fixture *construction* changes, e.g. wrapping literal source keys in a `Source`).
- No new dependencies (JSON encoding reuses the existing `Data.Aeson` + `dropPrefix` convention already used throughout `GrimDawn.Web.View`).
- Run `stack build` and `stack test` after every task; both must be clean (`-Wall`, per `gd-explorer-impl-notes`) before moving on.

---

### Task 1: Source attribution threaded through the stat pipeline + per-type damage detail

**Files:**
- Modify: `src/GrimDawn/Report/Stats.hs` (module export list, imports, new `Source`/`SourceCategory` section, `statSources`, `devotionSources`, `masterySources`, `skillSources`, `ScoreBase`/`mkScoreBase`/`estTotalDpsOf`/`scoreItems`/`findUpgrades`, `attackDps`'s internals)
- Modify: `src/GrimDawn/Web/View.hs` (`detailView`, `rankEnhancements`, `rankItems` — call sites that build `sources`/`extra`)
- Modify: `src/GrimDawn/Cli.hs` (three call sites building `extra`/`sources`)
- Modify: `test/GrimDawn/Report/StatsSpec.hs` (fixture updates — every literal `[("label", record)]` source list becomes `[(testSource "label", record)]`)

**Interfaces:**
- Produces: `Source (..)`, `SourceCategory (..)`, `mkSource :: Text -> SourceCategory -> Text -> Source`, `plainSources :: [(Source, Record)] -> [(Text, Record)]`, `SourceAmount (..)`, `TypeDetail (..)` — all exported from `GrimDawn.Report.Stats` for Task 2 and `GrimDawn.Web.View` to consume.
- Produces: `statSources`, `devotionSources`, `masterySources`, `skillSources`, `attackDps`, `mkScoreBase`, `findUpgrades` now take/return `[(Source, Record)]` where they previously used `[(Text, Record)]`. `attackDps`'s return type (`[AttackDps]`) is unchanged.
- Consumes (unchanged): `resistRows`, `keyTotalsOf`, `damageScore`, `statSummary`, `renderStats`, `renderStatsDiff` stay at `[(Text, Record)]` — callers now pass `plainSources someSources`.

This task also folds in the `typedDamage` rewrite (the spec's "flat contributions" / "percent contributions" / "retaliation" backend work) because it touches the exact same lines `sources`'s type change touches, and splitting them would mean writing throwaway intermediate code.

- [ ] **Step 1: Record the regression baseline**

Run: `stack test 2>&1 | tail -20`
Expected: all examples pass (note the exact count, e.g. "51 examples, 0 failures" — this task must reproduce that exact count at the end; it adds no new tests of its own, since `attackDps`'s observable behavior does not change).

- [ ] **Step 2: Add `Source`/`SourceCategory` and the per-type detail types**

In `src/GrimDawn/Report/Stats.hs`, add to the export list (after `parseDifficulty` / `difficultyPenalty`, before `statSources`):

```haskell
  , SourceCategory (..)
  , Source (..)
  , mkSource
  , plainSources
  , SourceAmount (..)
  , TypeDetail (..)
```

Update the imports (`Data.Maybe`, `GrimDawn.Gdc`):

```haskell
import Data.Maybe (fromMaybe, listToMaybe)
```
```haskell
import GrimDawn.Gdc (Character (..), Item (..), Skill (..), emptyItemName, itemWithName)
```

Add a new section right after the `import GrimDawn.Report.Color (colorByType)` line (before the `Difficulty` section):

```haskell
--------------------------------------------------------------------------------
-- Source attribution
--------------------------------------------------------------------------------

-- | The kind of thing that granted a stat-contributing record, for the DPS
-- attribution breakdown ('GrimDawn.Report.Stats.attackDpsBreakdown').
data SourceCategory
  = SrcGear | SrcComponent | SrcAugment | SrcSetBonus
  | SrcDevotion | SrcMastery | SrcSkill | SrcOther
  deriving (Show, Eq)

-- | A stat-contributing record's owner: a display label and category for
-- attribution, plus the original record-path key so existing dedup/equality
-- logic over @[(Text, Record)]@ keeps working unchanged — 'Eq'/'Ord' defer to
-- the key alone, ignoring label/category.
data Source = Source
  { srcKey :: !Text
  , srcLabel :: !Text
  , srcCategory :: !SourceCategory
  }
  deriving (Show)

instance Eq Source where
  a == b = srcKey a == srcKey b

instance Ord Source where
  compare a b = compare (srcKey a) (srcKey b)

mkSource :: Text -> SourceCategory -> Text -> Source
mkSource key cat label = Source key label cat

-- | Strip a 'Source'-tagged sources list back down to the plain
-- @[(Text, Record)]@ shape 'GrimDawn.Item''s aggregation helpers
-- ('GrimDawn.Item.sumField', 'GrimDawn.Item.sumRange', ...) and the plain
-- stat-summary functions below expect.
plainSources :: [(Source, Record)] -> [(Text, Record)]
plainSources = map (\(s, r) -> (srcKey s, r))

-- | One source's contribution to a flat amount or a percentage figure.
data SourceAmount = SourceAmount
  { saSource :: !Source
  , saValue :: !Double
  }
  deriving (Show, Eq)

-- | One damage type's full per-hit breakdown for a single attack/proc row:
-- the flat contributors (summing to 'tdFlatSubtotal'), and either the
-- immediate-damage percent contributors ('tdPercentSources') or — for a
-- damage-over-time row (label ends " (dot)") — the duration and damage
-- percent contributors kept separate, since a DoT's total is
-- @flatSubtotal x (1 + durationPct/100) x (1 + damagePct/100)@: two
-- multiplicative pools, not one. Immediate rows leave the duration/damage-pct
-- fields empty; DoT rows leave 'tdPercentSources'/'tdTotalPercent' empty.
data TypeDetail = TypeDetail
  { tdLabel :: !Text
  , tdTotal :: !Double
  , tdFlatSources :: ![SourceAmount]
  , tdFlatSubtotal :: !Double
  , tdPercentSources :: ![SourceAmount]
  , tdTotalPercent :: !Double
  , tdDurationSources :: ![SourceAmount]
  , tdTotalDurationPercent :: !Double
  , tdDamagePctSources :: ![SourceAmount]
  , tdTotalDamagePercent :: !Double
  }
  deriving (Show, Eq)

-- | The synthetic "source" for the retaliation-added-to-attack flat line in a
-- 'TypeDetail' — it's a computed aggregate of several real sources (see
-- 'GrimDawn.Report.Stats.retaliationByStem' in Task 2), not one source, so it
-- isn't further splittable within the flat table.
retaliationPseudoSource :: Source
retaliationPseudoSource = Source "__retaliation__" "Retaliation added to attack" SrcOther
```

- [ ] **Step 3: Run `stack build`**

Run: `stack build 2>&1 | tail -40`
Expected: compiles (these are new, unused-so-far definitions plus an import change — `retaliationPseudoSource` will show an "unused" warning until Task 2 uses it; that's fine to leave for now, it'll be consumed within this same task in Step 6).

- [ ] **Step 4: Rewrite `statSources`, `devotionSources`, `masterySources`, `skillSources` to tag each record with its `Source`**

Replace the existing `statSources` (currently `src/GrimDawn/Report/Stats.hs:110-124`):

```haskell
-- | Every stat-bearing record contributed by a character's equipped gear,
-- tagged with its owning 'Source' for the DPS attribution breakdown: each
-- item's base+affix records under one "Gear" source (the item's display
-- name), its relic (+relic-bonus) under a separate "Component" source, its
-- augment under a separate "Augment" source, plus each active set-completion
-- tier under a "Set Bonus" source. (Devotion and skill buffs are layered on
-- by callers later.)
statSources :: GameDb -> [Item] -> [(Source, Record)]
statSources db items =
  concatMap itemSources equipped ++ setTiers
  where
    equipped = filter (not . emptyItemName) items
    itemSources it =
      [ (mkSource n SrcGear (labelOf it), r)
      | n <-
          filter
            (T.isPrefixOf "records/")
            [itemBaseName it, itemPrefixName it, itemSuffixName it, itemModifierName it, itemTransmuteName it]
      , Just r <- [lookupRecord n db]
      ]
        ++ [ (mkSource n SrcComponent (labelOf (itemWithName (itemRelicName it))), r)
           | n <- [itemRelicName it, itemRelicBonus it]
           , not (T.null n)
           , Just r <- [lookupRecord n db]
           ]
        ++ [ (mkSource n SrcAugment (labelOf (itemWithName (itemAugmentName it))), r)
           | n <- [itemAugmentName it]
           , not (T.null n)
           , Just r <- [lookupRecord n db]
           ]
    labelOf it = iaDisplayName (itemAttrs it db)
    setRecs = [s | it <- equipped, Just s <- [setRecordName it db]]
    setTiers =
      [ (mkSource rec SrcSetBonus (setLabel rec r cnt), resolveSetTier cnt r)
      | rec <- nub setRecs
      , Just r <- [lookupRecord rec db]
      , let cnt = length (filter (== rec) setRecs)
      ]
    setLabel rec r cnt =
      fromMaybe (T.takeWhileEnd (/= '/') rec) (lookupField "setName" r >>= valueText)
        <> " ("
        <> T.pack (show cnt)
        <> "pc)"
```

Replace `devotionSources` (currently `src/GrimDawn/Report/Stats.hs:133-141`):

```haskell
devotionSources :: GameDb -> Character -> [(Source, Record)]
devotionSources db c =
  [ (mkSource (skName s) SrcDevotion (skillDisplayName db (skName s)), r)
  | s <- charSkills c
  , skLevel s > 0
  , "/devotion/tier" `T.isInfixOf` skName s
  , not ("_skill" `T.isSuffixOf` T.dropEnd 4 (skName s))
  , Just r <- [lookupRecord (skName s) db]
  ]
```

Replace `masterySources` (currently `src/GrimDawn/Report/Stats.hs:145-152`):

```haskell
masterySources :: GameDb -> Character -> [(Source, Record)]
masterySources db c =
  [ (mkSource (skName s) SrcMastery (skillDisplayName db (skName s)), resolveSetTier (fromIntegral (skLevel s)) r)
  | s <- charSkills c
  , "_classtraining_" `T.isInfixOf` skName s
  , skLevel s > 0
  , Just r <- [lookupRecord (skName s) db]
  ]
```

In `skillSources` (currently `src/GrimDawn/Report/Stats.hs:266-278`), change the signature, the tuple construction, and the `collectSkillLevels` call:

```haskell
skillSources :: BuffToggle -> [(Source, Record)] -> GameDb -> Character -> [(Source, Record)]
skillSources tog ctx db c =
  [ (mkSource (skName s) SrcSkill (skillDisplayName db (skName s)), resolveSetTier (effRank s) (buffStatRecord db skRec))
  | s <- charSkills c
  , skLevel s > 0
  , "records/skills/playerclass" `T.isPrefixOf` skName s
  , not ("_classtraining_" `T.isInfixOf` skName s)
  , Just skRec <- [lookupRecord (skName s) db]
  , Just cat <- [effectiveCategory skRec (skName s)]
  , allowed tog cat
  ]
  where
    effRank = rankWith (collectSkillLevels (plainSources ctx))
```

(the rest of `skillSources`'s `where` clause — `catByBase`, `effectiveCategory`, `isModifierLike` — is unchanged, it never touches `ctx`/`sources` directly).

- [ ] **Step 5: Thread `Source` through the upgrade-scoring path (`ScoreBase`, `mkScoreBase`, `estTotalDpsOf`, `scoreItems`, `findUpgrades`)**

In `ScoreBase` (currently `src/GrimDawn/Report/Stats.hs:754-764`), change one field:

```haskell
  , sbExtra :: ![(Source, Record)] -- non-gear sources (devotions, mastery, buffs)
```

In `mkScoreBase` (currently `src/GrimDawn/Report/Stats.hs:768-782`):

```haskell
mkScoreBase
  :: Weights -> Double -> Difficulty -> Character -> [(Source, Record)] -> GameDb -> [Item] -> ScoreBase
mkScoreBase w target diff c extra db base =
  let srcBase = statSources db base ++ extra
   in ScoreBase
        { sbWeights = w
        , sbTarget = target
        , sbDiff = diff
        , sbDb = db
        , sbChar = c
        , sbExtra = extra
        , sbBaseResists = resistRows diff (plainSources srcBase)
        , sbBaseKeyTotals = keyTotalsOf (plainSources srcBase)
        , sbBaseDps = estTotalDpsOf db c srcBase
        }
```

In `estTotalDpsOf` (currently `src/GrimDawn/Report/Stats.hs:785-790`), only the signature changes (body is unchanged — it already just forwards `src` straight into `attackDps`):

```haskell
estTotalDpsOf :: GameDb -> Character -> [(Source, Record)] -> Double
```

In `scoreItems` (currently `src/GrimDawn/Report/Stats.hs:793-817`), only the first three `let` lines change:

```haskell
scoreItems sb over =
  let srcO = statSources (sbDb sb) over ++ sbExtra sb
      rO = resistRows (sbDiff sb) (plainSources srcO)
      kO = keyTotalsOf (plainSources srcO)
```

(everything below — `pen`, `paired`, `changes`, `resScore`, `flatOf`, `oaD`, `daD`, `dpsD`, `w`, `allResistsMaxed`, `effectiveDamageWeight`, `sc` — is unchanged; `dpsD = estTotalDpsOf (sbDb sb) (sbChar sb) srcO - sbBaseDps sb` already passes `srcO` straight through, which is now correctly `Source`-tagged).

In `findUpgrades` (currently `src/GrimDawn/Report/Stats.hs:825-834`), only the signature changes:

```haskell
findUpgrades :: Weights -> Double -> Difficulty -> Int -> Character -> [(Source, Record)] -> GameDb -> [Item] -> [(Text, Item)] -> [UpgradeRow]
```

- [ ] **Step 6: Change `attackDps`'s sources type and rewrite `typedDamage` to build the per-source breakdown**

Change `attackDps`'s signature (currently `src/GrimDawn/Report/Stats.hs:921`):

```haskell
attackDps :: GameDb -> [(Source, Record)] -> Character -> [AttackDps]
```

In `attackDps`'s `where` clause, update every call into `GrimDawn.Item`'s Text-keyed helpers to go through `plainSources`. Currently (`src/GrimDawn/Report/Stats.hs:927-939`):

```haskell
    lv = collectSkillLevels sources
    totalPct = sumField sources "offensiveTotalDamageModifier"
    aps = assumedBaseAttackSpeed * (1 + sumField sources "characterAttackSpeedModifier" / 100)
    -- conversions from gear/buffs apply to every skill
    globalConv = concatMap (recordConversions . snd) sources
    pctOf stem = sumField sources ("offensive" <> stem <> "Modifier") + totalPct
```

becomes:

```haskell
    lv = collectSkillLevels (plainSources sources)
    totalPct = sumField (plainSources sources) "offensiveTotalDamageModifier"
    aps = assumedBaseAttackSpeed * (1 + sumField (plainSources sources) "characterAttackSpeedModifier" / 100)
    -- conversions from gear/buffs apply to every skill
    globalConv = concatMap (recordConversions . snd) sources
    pctOf stem = sumField (plainSources sources) ("offensive" <> stem <> "Modifier") + totalPct
```

Now replace `typedDamage` (currently `src/GrimDawn/Report/Stats.hs:1009-1051`) — this is the core rewrite. The new version returns `[TypeDetail]` instead of `[(Text, Double)]`, computing each source's own contribution alongside the aggregate:

```haskell
    -- Every source's raw (pre-conversion) flat contribution across damage
    -- stems, before % modifiers: gear/weapon sources (wpnPct-scaled), skill/
    -- modifier sources (their own flat, unscaled — matches the old `sflat`),
    -- and the retaliation-added-to-attack pseudo-source (below). One vector
    -- per source so conversions (a linear redistribution) can be applied
    -- per-source and still sum to the correct aggregate.
    rawFlatVectors :: Double -> [(Source, Int, Record)] -> [(Source, HM.HashMap Text Double)]
    rawFlatVectors wpnPct sibs =
      [ (s, vec)
      | (s, r) <- sources
      , let vec =
              HM.fromList
                [ (stem, v)
                | (stem, _) <- damageElems
                , let (lo, hi) = sumRange [(srcKey s, r)] ["offensive", "offensiveBase", "offensiveBonus"] stem
                      v = (lo + hi) / 2 * wpnPct / 100
                , v /= 0
                ]
      , not (HM.null vec)
      ]
        ++ [ (s, vec)
           | (s, i, r) <- sibs
           , let vec =
                   HM.fromList
                     [ (stem, v)
                     | (stem, _) <- damageElems
                     , let v =
                             ( maybe 0 (atRank i) (HM.lookup ("offensive" <> stem <> "Min") r)
                                 + maybe 0 (atRank i) (HM.lookup ("offensive" <> stem <> "Max") r)
                             )
                               / 2
                     , v /= 0
                     ]
           , not (HM.null vec)
           ]
        ++ [ (retaliationPseudoSource, HM.map rtdAddedToAttack byStem)
           | let byStem = retaliationByStem sources sibs
           , not (HM.null byStem)
           ]
    -- The retaliation-added-to-attack chain, keyed by raw stem token (e.g.
    -- "Fire"): each stem's own flat retaliation stat (x its own % modifiers)
    -- and the shared "% of retaliation damage added to attack" (global gear/
    -- buff sources plus any sibling skill's own value, e.g. Reprisal). This
    -- is the single computation both 'typedDamage' (feeding the aggregate
    -- flat term via 'rawFlatVectors' above) and 'attackDpsBreakdown' (Task 2)
    -- use, so the two can never disagree.
    retaliationByStem :: [(Source, Record)] -> [(Source, Int, Record)] -> HM.HashMap Text RetaliationTypeDetail
    retaliationByStem srcs sibs =
      HM.fromList
        [ (stem, d)
        | (stem, tok) <- damageElems
        , let d = mkDetail stem (effectDisplay ["offensive"] tok)
        , rtdFlatSubtotal d /= 0 || rtdAddedToAttack d /= 0
        ]
      where
        addContribs = retaliationAddToAttack srcs sibs
        addTotal = sum (map saValue addContribs)
        mkDetail stem lbl =
          RetaliationTypeDetail
            { rtdLabel = lbl
            , rtdFlatSources = flatContribs
            , rtdFlatSubtotal = flatSubtotal
            , rtdPercentSources = pctContribs
            , rtdTotalPercent = pctTotal
            , rtdRetaliationDamage = retalDamage
            , rtdAddedToAttack = retalDamage * addTotal / 100
            }
          where
            flatContribs =
              [ SourceAmount s v
              | (s, r) <- srcs
              , let (lo, hi) = sumRange [(srcKey s, r)] ["retaliation"] stem
                    v = (lo + hi) / 2
              , v /= 0
              ]
            flatSubtotal = sum (map saValue flatContribs)
            pctContribs =
              [ SourceAmount s v
              | (s, r) <- srcs
              , let v =
                      fromMaybe 0 (recNum r ("retaliation" <> stem <> "Modifier"))
                        + fromMaybe 0 (recNum r "retaliationTotalDamageModifier")
              , v /= 0
              ]
            pctTotal = sum (map saValue pctContribs)
            retalDamage = flatSubtotal * (1 + pctTotal / 100)
    retaliationAddToAttack :: [(Source, Record)] -> [(Source, Int, Record)] -> [SourceAmount]
    retaliationAddToAttack srcs sibs =
      [SourceAmount s v | (s, r) <- srcs, let v = fromMaybe 0 (recNum r "retaliationDamagePct"), v /= 0]
        ++ [SourceAmount s v | (s, i, r) <- sibs, let v = maybe 0 (atRank i) (HM.lookup "retaliationDamagePct" r), v /= 0]
    -- The per-type per-application damage for a group of contributing records
    -- @sibs@: weapon/gear flat (wpnPct-scaled) + retaliation-added-to-attack +
    -- skill/modifier flat, converted, then % modifiers. Plus the
    -- stacking-DoT term (duration% and damage% kept separate, since a DoT's
    -- total is flat x (1+duration%) x (1+damage%)). Replaces the old
    -- '[(Text,Double)]'-returning version: 'attackDps' derives its aggregate
    -- 'adTypes'/'adPerHit' by summing this; 'attackDpsBreakdown' (Task 2)
    -- exposes it directly.
    typedDamage :: Double -> [(Source, Int, Record)] -> [TypeDetail]
    typedDamage wpnPct sibs =
      [ TypeDetail
          { tdLabel = lbl
          , tdTotal = total
          , tdFlatSources = flatContribs
          , tdFlatSubtotal = flatSubtotal
          , tdPercentSources = pctContribs
          , tdTotalPercent = pctTotal
          , tdDurationSources = []
          , tdTotalDurationPercent = 0
          , tdDamagePctSources = []
          , tdTotalDamagePercent = 0
          }
      | (stem, tok) <- damageElems
      , let lbl = effectDisplay ["offensive"] tok
            convVecs = [(s, applyConversions convs v) | (s, v) <- rawFlatVectors wpnPct sibs]
            convs = globalConv ++ concatMap (recordConversions . (\(_, _, r) -> r)) sibs
            flatContribs = [SourceAmount s v | (s, vec) <- convVecs, let v = HM.lookupDefault 0 stem vec, v /= 0]
            flatSubtotal = sum (map saValue flatContribs)
            pctContribs =
              [ SourceAmount s v
              | (s, r) <- sources
              , let v = fromMaybe 0 (recNum r ("offensive" <> stem <> "Modifier")) + totalPct
              , v /= 0
              ]
            pctTotal = sum (map saValue pctContribs)
            total = flatSubtotal * (1 + pctTotal / 100)
      , total >= 1
      ]
        ++ [ TypeDetail
              { tdLabel = effectDisplay ["offensive", "slow"] tok <> " (dot)"
              , tdTotal = total
              , tdFlatSources = flatContribs
              , tdFlatSubtotal = flatSubtotal
              , tdPercentSources = []
              , tdTotalPercent = 0
              , tdDurationSources = durContribs
              , tdTotalDurationPercent = durTotal
              , tdDamagePctSources = dmgContribs
              , tdTotalDamagePercent = dmgTotal
              }
           | (stem, tok) <- dotElems
           , let dotRecs = srcRecsFor sources ++ sibs
                 perRec (i, r) =
                   ( maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Min") r)
                       + maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Max") r)
                   )
                     / 2
                 gearRaw = [(s, perRec (0, r) * wpnPct / 100) | (s, r) <- sources]
                 skillRaw = [(s, perRec (i, r)) | (s, i, r) <- sibs]
                 convs = globalConv ++ concatMap (recordConversions . (\(_, _, r) -> r)) sibs
                 rawVecs = [(s, HM.fromList [(stem, v)]) | (s, v) <- gearRaw ++ skillRaw, v /= 0]
                 convVecs = [(s, applyConversions convs v) | (s, v) <- rawVecs]
                 flatContribs = [SourceAmount s v | (s, vec) <- convVecs, let v = HM.lookupDefault 0 stem vec, v /= 0]
                 flatSubtotal = sum (map saValue flatContribs)
                 durContribs =
                   [ SourceAmount s v
                   | (s, i, r) <- dotRecs
                   , let v = maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "DurationModifier") r)
                   , v /= 0
                   ]
                 durTotal = sum (map saValue durContribs)
                 dmgContribs =
                   [SourceAmount s v | (s, r) <- sources, let v = totalPct, v /= 0]
                     ++ [ SourceAmount s v
                        | (s, i, r) <- dotRecs
                        , let v = maybe 0 (atRank i) (HM.lookup ("offensiveSlow" <> stem <> "Modifier") r)
                        , v /= 0
                        ]
                 dmgTotal = sum (map saValue dmgContribs)
                 total = flatSubtotal * (1 + durTotal / 100) * (1 + dmgTotal / 100)
           , total >= 1
           ]
      where
        srcRecsFor srcs = [(s, 0 :: Int, r) | (s, r) <- srcs]
```

`fieldNum`-equivalent note: this reuses the existing `recNum :: Record -> Text -> Maybe Double` already defined lower in `Stats.hs` (used today by `cdrContrib`) — no new helper needed.

Now fix every remaining caller of the old `typedDamage`. `mkRow` (currently `src/GrimDawn/Report/Stats.hs:1054-1065`):

```haskell
    mkRow name mRank wpnPct cdBase sibs =
      let cdr = srcCdr + sum [cdrContrib i rr | (i, rr) <- map (\(_, i, r) -> (i, r)) sibs]
          cd = max 0.1 (cdBase * (1 - cdr / 100))
          typed = typedDamage wpnPct sibs
          perHit = sum (map tdTotal typed)
          (dps, rate)
            | cdBase > 0 = (perHit / cd, oneDp cd <> "s cooldown")
            | wpnPct > 0 = (perHit * aps, "~" <> oneDp aps <> "/s attacks (assumed base)")
            | otherwise = (0, "")
       in if perHit <= 0 || T.null rate
            then Nothing
            else Just (AttackDps name mRank Active perHit dps rate [(tdLabel t, tdTotal t) | t <- typed])
```

`emitWps` (currently `src/GrimDawn/Report/Stats.hs:991-1000`):

```haskell
    emitWps s r =
      let sibs = sibsOf s
          rank = rankWith lv s
          chance = maybe 0 (atRank (rank - 1)) (HM.lookup "skillChanceWeight" r) / 100
          typed = typedDamage (aggIn (map (\(_, i, rr) -> (i, rr)) sibs) "weaponDamagePct") sibs
          perHit = sum (map tdTotal typed)
          rate = showInt (chance * 100) <> "% WPS on attack"
       in if perHit <= 0 || chance <= 0
            then Nothing
            else Just (AttackDps (skillDisplayName db (skName s)) (Just rank) Triggered perHit (perHit * chance * aps) rate [(tdLabel t, tdTotal t) | t <- typed])
```

`mkProc` (currently `src/GrimDawn/Report/Stats.hs:1070-1075`):

```haskell
    mkProc name rank rec p cd trig =
      let typed = typedDamage 0 [(mkSource "__proc__" SrcSkill name, rank - 1, rec)]
          perHit = sum (map tdTotal typed)
          interval = cd + 1 / max 0.01 (p * aps)
          rate = showInt (p * 100) <> "% on " <> trig <> ", " <> oneDp cd <> "s cd"
       in if perHit <= 0 then Nothing else Just (AttackDps name Nothing Triggered perHit (perHit / interval) rate [(tdLabel t, tdTotal t) | t <- typed])
```

And `sibsOf` (currently `src/GrimDawn/Report/Stats.hs:977-984`) now carries each sibling's own `Source`:

```haskell
    sibsOf s =
      [ (mkSource (skName sib) SrcSkill (skillDisplayName db (skName sib)), rankWith lv sib - 1, rr)
      | sib <- charSkills c
      , skillBase (skName sib) == skillBase (skName s)
      , skLevel sib > 0
      , Just rr <- [lookupRecord (skName sib) db]
      , skName sib == skName s || not (isPrimary rr)
      ]
```

`aggIn` (currently `src/GrimDawn/Report/Stats.hs:950`) is still used above for `weaponDamagePct` against the remapped `(Int, Record)` list — leave its own definition (`aggIn recs key = sum [maybe 0 (atRank i) (HM.lookup key r) | (i, r) <- recs]`) unchanged, it never inspected the sources' `fst` type.

Finally, `emit` (currently `src/GrimDawn/Report/Stats.hs:985-987`) is unaffected (it just calls `mkRow`/`sibsOf`/`aggIn` — no direct `typedDamage`/sources access of its own beyond what's already covered).

- [ ] **Step 7: Build and fix remaining type errors**

Run: `stack build 2>&1 | tail -80`

Fix every reported type error by locating the call site GHC points to and wrapping the offending `[(Text, Record)]`-shaped value with the appropriate conversion (`plainSources` to go from `Source`-tagged to plain, or the corresponding `statSources`/`devotionSources`/`masterySources`/`skillSources` call is already `Source`-tagged and just needs no wrap). Expect errors in `src/GrimDawn/Web/View.hs` and `src/GrimDawn/Cli.hs` — fix them now (do not defer):

In `src/GrimDawn/Web/View.hs`, `detailView` (currently around line 465-505): everywhere `sources` is passed into `sumField`/`statSummary`, wrap with `plainSources`:

```haskell
    cdvSummary = toSummaryView difficulty (statSummary difficulty c (plainSources sources))
    cdvAttacks = map toAttackView (attackDps db sources c) -- unchanged: sources is already Source-tagged
    cdvGear = map gearViewOf items
    cdvArmorTable = armorTable items
    cdvShopping = shoppingList db c owned (map slotTypeOf items) (equippedItems c) items
    cdvMasteries = buildMasteries db c
    cdvDevotions = buildDevotions db c
```

(`cdvGear`/`cdvShopping`/`cdvMasteries`/`cdvDevotions`/`gearViewOf`/`slotTypeOf` are listed only to show they stay exactly as they are today — they never touch `sources`.) Further down in the same `where` clause:

```haskell
    pieceArmor it = sumField (plainSources (statSources db [it])) "defensiveProtection"
    globalArmorPct = sumField (plainSources sources) "defensiveProtectionModifier"
    armorTable its =
      let displayed = map fst armorSlotLabels
          globalFlat =
            sumField (plainSources sources) "defensiveProtection"
              - sum [pieceArmor it | it <- its, iaType (itemAttrs it db) `elem` map Just displayed]
       in [ NamedValueView label ((pieceArmor it + globalFlat) * (1 + globalArmorPct / 100))
          | (slotKey, label) <- armorSlotLabels
          , it <- its
          , iaType (itemAttrs it db) == Just slotKey
          ]
```

(the list comprehension inside `armorTable`'s `in` is unchanged from today — only the two `sumField sources ...` lines above it gain `plainSources`).

Add `plainSources` to the `GrimDawn.Report.Stats` import list in `src/GrimDawn/Web/View.hs`. `rankEnhancements` and `rankItems` need no changes — they already pass `extra`/`sources` straight into `mkScoreBase`, which now expects `Source`-tagged input.

In `src/GrimDawn/Cli.hs`, wrap the two `renderStats*` call sites (currently lines 294 and 296) with `plainSources`:

```haskell
              TIO.putStr (renderStatsDiff useColor (coDifficulty copts) (plainSources extra) db base effective)
            TIO.putStrLn ""
            TIO.putStr (renderStats useColor (coDifficulty copts) c (plainSources extra) db effective)
```

Add `plainSources` to the `GrimDawn.Report.Stats` import list in `src/GrimDawn/Cli.hs`. The `findUpgrades` (line 318) and `attackDps` (line 360) call sites need no changes — `extra`/`sources` are already `Source`-tagged there and both functions now expect that.

Run: `stack build 2>&1 | tail -80`
Expected: still errors, but only in `test/GrimDawn/Report/StatsSpec.hs` now (production code compiles clean).

- [ ] **Step 8: Fix `test/GrimDawn/Report/StatsSpec.hs` fixtures**

Add a test helper near the top of the file, after the existing `mkChar`:

```haskell
-- a throwaway Source for fixtures that don't care about label/category, keyed
-- by the same string the old tests used as the sources-list label.
testSource :: T.Text -> Source
testSource n = Source n n SrcOther
```

Add `Source (..)`, `SourceCategory (..)` to the `GrimDawn.Report.Stats` import list.

Run: `stack build 2>&1 | tail -80` and follow each remaining type error to its line in `StatsSpec.hs`. Every literal source list of the shape `[("label", HM.fromList [...])]` becomes `[(testSource "label", HM.fromList [...])]`; every `map fst (skillSources ...)` comparison against a list of `Text` record paths becomes `map (srcKey . fst) (skillSources ...)`; every `renderStats ... extra synthDb ...` / `renderStatsDiff` call where `extra` came from `devotionSources`/`skillSources` (already `Source`-tagged) needs `(plainSources extra)` in place of bare `extra`. Concretely, at minimum:

- `it "includes devotion passive bonuses as extra sources"`: `renderStats False Normal ch extra synthDb []` → `renderStats False Normal ch (plainSources extra) synthDb []`.
- `it "skill buffs respect the category toggle and skip modifiers"`: both `map fst (skillSources permOnly [] synthDb ch)` calls → `map (srcKey . fst) (...)`; the `renderStats False Normal ch (skillSources permOnly [] synthDb ch) synthDb []` call → wrap with `plainSources`.
- `it "folds a skill modifier in under its parent skill's category"`: `names = map fst (...)` → `map (srcKey . fst) (...)`; the `renderStats ... (skillSources perm [] synthDb ch) ...` call → wrap with `plainSources`.
- `it "scales skill buffs by +skills from the context"`: `ctx = [("gear", HM.fromList [("augmentAllLevel", VFloat 1)])]` → `ctx = [(testSource "gear", HM.fromList [("augmentAllLevel", VFloat 1)])]`; both `renderStats ... (skillSources perm ctx synthDb ch) ...` / `(skillSources perm [] synthDb ch)` calls → wrap with `plainSources`.
- Every `attackDps synthDb sources ch` / `attackDps synthDb [] ch` / `attackDps synthDb sources (mkChar [])` call whose `sources` is a literal `[("wpn", ...)]` / `[("wpn", ...), ("conv", ...)]` / `[("wpn", ...), ("retal", ...)]` / `[("wpn", ...), ("relic", ...)]` list: wrap each label in `testSource`, e.g. `[(testSource "wpn", HM.fromList [...])]`.

Run: `stack build 2>&1 | tail -80`
Expected: clean build, no errors.

- [ ] **Step 9: Verify the regression baseline still holds**

Run: `stack test 2>&1 | tail -20`
Expected: the exact same example count and 0 failures recorded in Step 1. If any assertion fails, the `typedDamage` rewrite changed a number — debug by comparing the failing test's expected value against the old formula (`flatOf`/`immediate`/`dot` in the pre-Task-1 version of the function, visible via `git diff`) before changing anything else.

- [ ] **Step 10: Commit**

```bash
git add src/GrimDawn/Report/Stats.hs src/GrimDawn/Web/View.hs src/GrimDawn/Cli.hs test/GrimDawn/Report/StatsSpec.hs
git commit -m "$(cat <<'EOF'
Thread source attribution through the stat/DPS pipeline

statSources/devotionSources/masterySources/skillSources now tag each
record with its owning Source (display label + category) instead of a
bare record path. attackDps's internal typedDamage is rewritten to
build the per-source flat/percent/retaliation breakdown as its
primary computation, with the existing aggregate output derived by
summing it, so a later per-row breakdown can never disagree with the
summary panel's numbers. No observable behavior change (attackDps's
output and all existing tests are unchanged).
EOF
)"
```

---

### Task 2: `attackDpsBreakdown` — rate factors, trigger info, row detail, and DPS-impact ranking

**Files:**
- Modify: `src/GrimDawn/Report/Stats.hs` (new types, new internal `RowDetail`/`attackDpsRows`, new exported `attackDpsBreakdown`, rate-factor calc functions)
- Modify: `test/GrimDawn/Report/StatsSpec.hs` (new tests for `attackDpsBreakdown`)

**Interfaces:**
- Consumes: `Source`, `SourceCategory`, `mkSource`, `plainSources`, `SourceAmount`, `TypeDetail`, `retaliationPseudoSource` from Task 1; the rewritten `typedDamage`/`retaliationByStem`/`retaliationAddToAttack` closures inside `attackDps`'s `where` block.
- Produces: `RetaliationTypeDetail (..)`, `RetaliationDetail (..)`, `RateFactorDetail (..)`, `TriggerDetail (..)`, `SourceImpact (..)`, `AttackBreakdown (..)`, `attackDpsBreakdown :: GameDb -> [(Source, Record)] -> Character -> Text -> Maybe Int -> AttackKind -> Maybe AttackBreakdown` — all exported from `GrimDawn.Report.Stats` for Task 3 (`GrimDawn.Web.View`) to consume.

- [ ] **Step 1: Write the failing tests**

Update the imports at the top of `test/GrimDawn/Report/StatsSpec.hs`: add `import Data.List (find)` (not currently imported in this file), and add the new Task 2 names to the existing `GrimDawn.Report.Stats` import list (which already has `Source (..)`, `SourceCategory (..)` from Task 1):

```haskell
  ( AttackBreakdown (..)
  , AttackDps (..)
  , AttackKind (..)
  , BuffToggle (..)
  , Difficulty (..)
  , RateFactorDetail (..)
  , RetaliationDetail (..)
  , RetaliationTypeDetail (..)
  , Source (..)
  , SourceAmount (..)
  , SourceCategory (..)
  , SourceImpact (..)
  , TriggerDetail (..)
  , TypeDetail (..)
  , UpgradeRow (..)
  , attackDps
  , attackDpsBreakdown
  , defaultWeights
  , devotionSources
  , findUpgrades
  , noBuffs
  , overlay
  , overlayAt
  , parseBuffs
  , parseProcController
  , renderStats
  , skillSources
  )
```

Add to `test/GrimDawn/Report/StatsSpec.hs`, after the existing `attackDps`-related `it` blocks (before `it "parseProcController reads attack-driven trigger + chance, skipping others"`):

```haskell
  describe "attackDpsBreakdown" $ do
    it "attributes flat and percent contributions per damage type" $ do
      let ch = mkChar [mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1]
          sources =
            [ (Source "wpn" "Test Weapon" SrcGear, HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])
            , (Source "ring" "Test Ring" SrcGear, HM.fromList [("offensiveFireModifier", VFloat 20)])
            ]
      case attackDpsBreakdown synthDb sources ch "Testatk1" (Just 1) Active of
        Nothing -> expectationFailure "expected a breakdown"
        Just bd -> do
          abPerHit bd `shouldBe` adPerHit (head (skillRows (attackDps synthDb sources ch)))
          case find ((== "Physical") . tdLabel) (abTypes bd) of
            Just t -> do
              map saValue (tdFlatSources t) `shouldBe` [100]
              tdFlatSubtotal t `shouldBe` 100
            Nothing -> expectationFailure "expected a Physical TypeDetail"
          case find ((== "Fire") . tdLabel) (abTypes bd) of
            Just t -> do
              map saValue (tdFlatSources t) `shouldBe` [50] -- atk1's own flat fire
              map (srcLabel . saSource) (tdPercentSources t) `shouldBe` ["Test Ring"]
              tdTotalPercent t `shouldBe` 20
              tdTotal t `shouldBe` 60 -- 50 x 1.2
            Nothing -> expectationFailure "expected a Fire TypeDetail"

    it "attributes retaliation added to attack across its flat/pct/add-to-attack sources" $ do
      let ch = mkChar [mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1]
          sources =
            [ (Source "wpn" "Test Weapon" SrcGear, HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])
            , (Source "shield" "Test Shield" SrcGear, HM.fromList [("retaliationFireMin", VFloat 200), ("retaliationFireMax", VFloat 200)])
            , (Source "reprisal" "Reprisal" SrcSkill, HM.fromList [("retaliationDamagePct", VFloat 50)])
            ]
      case attackDpsBreakdown synthDb sources ch "Testatk1" (Just 1) Active of
        Nothing -> expectationFailure "expected a breakdown"
        Just bd -> case abRetaliation bd of
          Nothing -> expectationFailure "expected a retaliation section"
          Just rd -> do
            map (srcLabel . saSource) (rdAddToAttackSources rd) `shouldBe` ["Reprisal"]
            rdTotalAddToAttackPct rd `shouldBe` 50
            case find ((== "Fire") . rtdLabel) (rdByType rd) of
              Just t -> do
                map (srcLabel . saSource) (rtdFlatSources t) `shouldBe` ["Test Shield"]
                rtdFlatSubtotal t `shouldBe` 200
                rtdRetaliationDamage t `shouldBe` 200
                rtdAddedToAttack t `shouldBe` 100 -- 200 x 50%
              Nothing -> expectationFailure "expected a Fire RetaliationTypeDetail"
            -- the same 100 should also show up as a flat "Retaliation added to
            -- attack" line in the Fire TypeDetail, matching the aggregate
            -- attackDps number this test's sibling ("attackDps adds
            -- retaliation damage to attack") already asserts on (50 skill
            -- flat + 100 retaliation-added = 150).
            case find ((== "Fire") . tdLabel) (abTypes bd) of
              Just t -> map saValue (tdFlatSources t) `shouldContain` [100]
              Nothing -> expectationFailure "expected a Fire TypeDetail"

    it "reports cooldown-reduction rate factors for a cooldown-based attack" $ do
      let ch =
            mkChar
              [ mkSkillLvl "records/skills/playerclass01/cdr1.dbr" 1
              , mkSkillLvl "records/skills/playerclass01/cdr1b.dbr" 1
              ]
      case attackDpsBreakdown synthDb [] ch "Testcdr1" (Just 1) Active of
        Nothing -> expectationFailure "expected a breakdown"
        Just bd -> case find ((== "Cooldown Reduction") . rfdLabel) (abRateFactors bd) of
          Just rf -> do
            rfdBase rf `shouldBe` 4
            rfdEffective rf `shouldBe` 3 -- 4 x (1 - 0.25)
          Nothing -> expectationFailure "expected a Cooldown Reduction rate factor"

    it "reports a proc's trigger info instead of contributor rate factors" $ do
      let sources =
            [ (Source "wpn" "Test Weapon" SrcGear, HM.fromList [("offensivePhysicalMin", VFloat 1), ("offensivePhysicalMax", VFloat 1)])
            , (Source "relic" "Test Relic" SrcComponent, gdbRecords synthDb HM.! "records/items/relicProc.dbr")
            ]
      case attackDpsBreakdown synthDb sources (mkChar []) "Testproc" Nothing Triggered of
        Nothing -> expectationFailure "expected a breakdown"
        Just bd -> case abTrigger bd of
          Just trg -> do
            trgChancePct trg `shouldBe` 50
            trgCooldown trg `shouldBe` 2
            trgGrantedBy trg `shouldBe` "Test Relic"
          Nothing -> expectationFailure "expected trigger info"

    it "ranks sources by DPS impact, largest magnitude first" $ do
      let ch = mkChar [mkSkillLvl "records/skills/playerclass01/atk1.dbr" 1]
          sources =
            [ (Source "wpn" "Test Weapon" SrcGear, HM.fromList [("offensivePhysicalMin", VFloat 100), ("offensivePhysicalMax", VFloat 100)])
            , (Source "ring" "Test Ring" SrcGear, HM.fromList [("offensiveFireModifier", VFloat 20)])
            ]
      case attackDpsBreakdown synthDb sources ch "Testatk1" (Just 1) Active of
        Nothing -> expectationFailure "expected a breakdown"
        Just bd -> do
          let impacts = [(srcLabel (siSource i), siDpsImpact i) | i <- abSourcesByImpact bd]
          lookup "Test Weapon" impacts `shouldSatisfy` maybe False (> 0) -- removing the weapon loses the most dps
          case impacts of
            ((topLabel, topImpact) : _) -> do
              topLabel `shouldBe` "Test Weapon"
              (topImpact > 0) `shouldBe` True
            [] -> expectationFailure "expected at least one impact row"
```

Note this test file references `Testatk1`/`Testcdr1` as the expected `adName` — check the actual `skillDisplayName` fallback for these synthetic records (they have no `skillDisplayName` field, so `skillDisplayName db "records/skills/playerclass01/atk1.dbr"` falls back to some derived name). Before running, confirm the exact fallback string by checking `skillDisplayName`'s implementation in `src/GrimDawn/Item.hs` (grep for `skillDisplayName ::`) and adjust the literal `"Testatk1"`/`"Testcdr1"` strings in the steps above to match whatever it actually returns for these paths (likely the trailing path segment title-cased, or similar — read the function rather than guessing).

- [ ] **Step 2: Confirm the tests fail to compile (the new functions/types don't exist yet)**

Run: `stack test 2>&1 | tail -60`
Expected: compile errors — `Variable not in scope: attackDpsBreakdown`, `Data constructor not in scope: Source`, etc. (`Source`/`SourceCategory` already exist from Task 1, so those specific errors won't appear — only the new-in-this-task names will).

- [ ] **Step 3: Add the remaining breakdown types**

In `src/GrimDawn/Report/Stats.hs`'s export list, add:

```haskell
  , RetaliationTypeDetail (..)
  , RetaliationDetail (..)
  , RateFactorDetail (..)
  , TriggerDetail (..)
  , SourceImpact (..)
  , AttackBreakdown (..)
  , attackDpsBreakdown
```

Add the type definitions, right after `TypeDetail` (from Task 1):

```haskell
-- | Retaliation's own flat -> % -> % chain for one damage type (see
-- 'RetaliationDetail').
data RetaliationTypeDetail = RetaliationTypeDetail
  { rtdLabel :: !Text
  , rtdFlatSources :: ![SourceAmount]
  , rtdFlatSubtotal :: !Double
  , rtdPercentSources :: ![SourceAmount]
  , rtdTotalPercent :: !Double
  , rtdRetaliationDamage :: !Double -- flatSubtotal x (1 + totalPercent/100)
  , rtdAddedToAttack :: !Double -- retaliationDamage x (shared add-to-attack %)/100
  }
  deriving (Show, Eq)

-- | Retaliation damage added to an attack: the shared "% of retaliation
-- damage added to attack" (one scalar, applied to every damage type), and
-- each affected type's own flat/percent retaliation chain.
data RetaliationDetail = RetaliationDetail
  { rdAddToAttackSources :: ![SourceAmount]
  , rdTotalAddToAttackPct :: !Double
  , rdByType :: ![RetaliationTypeDetail]
  }
  deriving (Show, Eq)

-- | A rate-affecting factor (attack speed, cooldown reduction, weapon
-- damage %) and the sources contributing to it.
data RateFactorDetail = RateFactorDetail
  { rfdLabel :: !Text
  , rfdBase :: !Double
  , rfdSources :: ![SourceAmount]
  , rfdEffective :: !Double
  , rfdFormula :: !Text
  }
  deriving (Show, Eq)

-- | A proc's trigger: chance, base cooldown, and the single record that
-- grants it (only one record ever grants a given proc, unlike the
-- contributor lists above).
data TriggerDetail = TriggerDetail
  { trgChancePct :: !Double
  , trgCooldown :: !Double
  , trgGrantedBy :: !Text
  }
  deriving (Show, Eq)

-- | One source's estimated impact on a row's DPS: the row's current DPS
-- minus its DPS with that source's records excluded, holding everything
-- else fixed. Independent counterfactuals — not required to sum to the
-- row's total DPS (see the design doc's "Why flat and % stay separate").
data SourceImpact = SourceImpact
  { siSource :: !Source
  , siDpsImpact :: !Double
  }
  deriving (Show, Eq)

-- | The full source-attributed breakdown for one attack/proc row.
data AttackBreakdown = AttackBreakdown
  { abName :: !Text
  , abRank :: !(Maybe Int)
  , abKind :: !AttackKind
  , abPerHit :: !Double
  , abDps :: !Double
  , abRate :: !Text
  , abSourcesByImpact :: ![SourceImpact]
  , abTypes :: ![TypeDetail]
  , abRetaliation :: !(Maybe RetaliationDetail)
  , abRateFactors :: ![RateFactorDetail]
  , abTrigger :: !(Maybe TriggerDetail)
  }
  deriving (Show, Eq)

-- | One row's full detail: the existing summary ('AttackDps'), plus every
-- piece 'attackDpsBreakdown' needs, plus the distinct sources that touched
-- it (for the DPS-impact ranking). Computed once per row inside
-- 'attackDpsRows' so 'attackDps' (which just projects 'rdSummary') and
-- 'attackDpsBreakdown' can never disagree.
data RowDetail = RowDetail
  { rdSummary :: !AttackDps
  , rdTypes :: ![TypeDetail]
  , rdRetaliation :: !(Maybe RetaliationDetail)
  , rdRateFactors :: ![RateFactorDetail]
  , rdTrigger :: !(Maybe TriggerDetail)
  , rdSourcesTouched :: ![Source]
  }
```

- [ ] **Step 4: Restructure `attackDps`'s body into `attackDpsRows`, add rate-factor calcs, and implement `attackDpsBreakdown`**

Rename the current `attackDps`'s equation and `where` clause (from Task 1's Step 6 state) to a new internal function `attackDpsRows`, taking an extra leading `Maybe Text` parameter (the source key to exclude, for DPS-impact recomputation — `Nothing` for a normal call):

```haskell
attackDps :: GameDb -> [(Source, Record)] -> Character -> [AttackDps]
attackDps db sources0 c = map rdSummary (attackDpsRows Nothing db sources0 c)

-- | Every attack/proc row's full detail (see 'RowDetail'). @exclude@, when
-- set, removes every record tagged with that 'srcKey' from both the sources
-- list and any skill sibling before computing — used by 'attackDpsBreakdown'
-- to measure a single source's DPS impact by recomputing without it.
attackDpsRows :: Maybe Text -> GameDb -> [(Source, Record)] -> Character -> [RowDetail]
attackDpsRows exclude db sources0 c =
  sortOn (negate . adDps . rdSummary) actives ++ sortOn (negate . adDps . rdSummary) procs
  where
    sources = filter (\(s, _) -> Just (srcKey s) /= exclude) sources0
    excluded sk = Just sk == exclude
    -- < everything from the current attackDps's where-clause carries over
    --   unchanged from Task 1's Step 6 state, EXCEPT: >
    --   1. `sibsOf` additionally filters out any sibling whose own skName
    --      matches `exclude`:
    --        sibsOf s =
    --          [ (mkSource (skName sib) SrcSkill (skillDisplayName db (skName sib)), rankWith lv sib - 1, rr)
    --          | sib <- charSkills c
    --          , not (excluded (skName sib))
    --          , skillBase (skName sib) == skillBase (skName s)
    --          , skLevel sib > 0
    --          , Just rr <- [lookupRecord (skName sib) db]
    --          , skName sib == skName s || not (isPrimary rr)
    --          ]
    --   2. every row-producing function (`mkRow`, `emitWps`, `mkProc`,
    --      `weaponRow`) builds a `RowDetail` instead of directly building
    --      `AttackDps` — see below.
```

Rewrite `mkRow` to build a `RowDetail`, adding the rate-factor calcs:

```haskell
    attackSpeedCalc =
      let contribs = [SourceAmount s v | (s, r) <- sources, let v = fromMaybe 0 (recNum r "characterAttackSpeedModifier"), v /= 0]
          total = sum (map saValue contribs)
          eff = assumedBaseAttackSpeed * (1 + total / 100)
       in RateFactorDetail "Attack Speed" assumedBaseAttackSpeed contribs eff (oneDp assumedBaseAttackSpeed <> " x (1 + " <> showInt total <> "%) = " <> oneDp eff <> "/s")
    cooldownReductionCalc baseCd sibs =
      let gearContribs = [SourceAmount s v | (s, r) <- sources, let v = cdrContrib 0 r, v /= 0]
          sibContribs = [SourceAmount s v | (s, i, r) <- sibs, let v = cdrContrib i r, v /= 0]
          contribs = gearContribs ++ sibContribs
          total = sum (map saValue contribs)
          eff = max 0.1 (baseCd * (1 - total / 100))
       in RateFactorDetail "Cooldown Reduction" baseCd contribs eff (oneDp baseCd <> "s x (1 - " <> showInt total <> "%) = " <> oneDp eff <> "s")
    weaponDamagePctCalc sibs =
      let contribs = [SourceAmount s v | (s, i, r) <- sibs, let v = maybe 0 (atRank i) (HM.lookup "weaponDamagePct" r), v /= 0]
          total = sum (map saValue contribs)
       in RateFactorDetail "Weapon Damage %" 0 contribs total (showInt total <> "% weapon damage")

    mkRow name mRank wpnPct cdBase sibs =
      let cdrCalc = cooldownReductionCalc cdBase sibs
          cd = rfdEffective cdrCalc
          typed = typedDamage wpnPct sibs
          perHit = sum (map tdTotal typed)
          retal = retaliationDetailFor sources sibs
          (dps, rate, rateFactors)
            | cdBase > 0 = (perHit / cd, oneDp cd <> "s cooldown", [cdrCalc])
            | wpnPct > 0 =
                ( perHit * rfdEffective attackSpeedCalc
                , "~" <> oneDp (rfdEffective attackSpeedCalc) <> "/s attacks (assumed base)"
                , [attackSpeedCalc, weaponDamagePctCalc sibs]
                )
            | otherwise = (0, "", [])
       in if perHit <= 0 || T.null rate
            then Nothing
            else
              Just
                RowDetail
                  { rdSummary = AttackDps name mRank Active perHit dps rate [(tdLabel t, tdTotal t) | t <- typed]
                  , rdTypes = typed
                  , rdRetaliation = retal
                  , rdRateFactors = rateFactors
                  , rdTrigger = Nothing
                  , rdSourcesTouched = nub (map fst sources ++ [s | (s, _, _) <- sibs])
                  }
```

where `retaliationDetailFor` assembles the row-level `RetaliationDetail` from `retaliationByStem`/`retaliationAddToAttack` — already `where`-bound as siblings of `typedDamage` (not nested inside it) in Task 1's Step 6, so both `typedDamage` and `retaliationDetailFor` can call them directly:

```haskell
    retaliationDetailFor srcs sibs
      | HM.null byStem = Nothing
      | otherwise = Just (RetaliationDetail addContribs (sum (map saValue addContribs)) (HM.elems byStem))
      where
        byStem = retaliationByStem srcs sibs
        addContribs = retaliationAddToAttack srcs sibs
```

Update `emitWps` (currently `src/GrimDawn/Report/Stats.hs:991-1000`) to build a `RowDetail`, same shape as `mkRow`'s weapon%-branch:

```haskell
    emitWps s r =
      let sibs = sibsOf s
          rank = rankWith lv s
          chance = maybe 0 (atRank (rank - 1)) (HM.lookup "skillChanceWeight" r) / 100
          wdpCalc = weaponDamagePctCalc sibs
          typed = typedDamage (rfdEffective wdpCalc) sibs
          perHit = sum (map tdTotal typed)
          rate = showInt (chance * 100) <> "% WPS on attack"
       in if perHit <= 0 || chance <= 0
            then Nothing
            else
              Just
                RowDetail
                  { rdSummary = AttackDps (skillDisplayName db (skName s)) (Just rank) Triggered perHit (perHit * chance * rfdEffective attackSpeedCalc) rate [(tdLabel t, tdTotal t) | t <- typed]
                  , rdTypes = typed
                  , rdRetaliation = retaliationDetailFor sources sibs
                  , rdRateFactors = [attackSpeedCalc, wdpCalc]
                  , rdTrigger = Nothing
                  , rdSourcesTouched = nub (map fst sources ++ [s' | (s', _, _) <- sibs])
                  }
```

`mkProc` now takes the granting `Source` as an explicit parameter (instead of inferring nothing about who granted it), used both for the trigger's display label and for `rdSourcesTouched` — and reused as the tag on the proc's own damage record when calling `typedDamage`, so the proc's `tdFlatSources` shows one contributor: the granting item/devotion/skill itself. Replace `mkProc` (currently `src/GrimDawn/Report/Stats.hs:1070-1075`):

```haskell
    mkProc name rank rec p cd trig grantedBy =
      let typed = typedDamage 0 [(grantedBy, rank - 1, rec)]
          perHit = sum (map tdTotal typed)
          interval = cd + 1 / max 0.01 (p * aps)
          rate = showInt (p * 100) <> "% on " <> trig <> ", " <> oneDp cd <> "s cd"
       in if perHit <= 0
            then Nothing
            else
              Just
                RowDetail
                  { rdSummary = AttackDps name Nothing Triggered perHit (perHit / interval) rate [(tdLabel t, tdTotal t) | t <- typed]
                  , rdTypes = typed
                  , rdRetaliation = Nothing
                  , rdRateFactors = []
                  , rdTrigger = Just (TriggerDetail (p * 100) cd (srcLabel grantedBy))
                  , rdSourcesTouched = [grantedBy]
                  }
```

where `aps` in this `where`-clause is `rfdEffective attackSpeedCalc` (used above by `mkRow`/`emitWps`) — update the reference at `interval = cd + 1 / max 0.01 (p * aps)` accordingly if `aps` was previously a bare `let`-bound name; keep the same binding, just sourced from `attackSpeedCalc` now instead of the old inline formula.

Update `mkProc`'s three call sites (currently `src/GrimDawn/Report/Stats.hs:1079-1109`) to pass the granting `Source` and to respect `exclude`:

```haskell
    -- procs granted by equipped items (itemSkillName + a cast_@... controller)
    itemProcs =
      [ mkProc (skillDisplayName db skn) rank rec p cd trig grantedBy
      | (skn, ir, grantedBy) <-
          nubBy (\(a, _, _) (b, _, _) -> a == b)
            [(s, ir, srcOfIr) | (srcOfIr, ir) <- sources, not (excluded (srcKey srcOfIr)), Just s <- [lookupField "itemSkillName" ir >>= valueText]]
      , Just rec <- [lookupRecord skn db]
      , Just (trig, p) <- [lookupField "itemSkillAutoController" ir >>= valueText >>= parseProcController]
      , let rank = levelOf (lookupField "itemSkillLevelEq" ir)
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
    -- procs bound to invested devotion stars (templateAutoCast controller)
    devoProcs =
      [ mkProc (skillDisplayName db (skName s)) rank rec p cd trig (mkSource (skName s) SrcDevotion (skillDisplayName db (skName s)))
      | s <- charSkills c
      , not (excluded (skName s))
      , "skills/devotion" `T.isInfixOf` skName s
      , skLevel s > 0
      , Just rec <- [lookupRecord (skName s) db]
      , Just (trig, p) <- [lookupField "templateAutoCast" rec >>= valueText >>= parseProcController]
      , let rank = rankWith lv s
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
    -- learned skills that fire on hit (Skill_OnHit*), e.g. Vindictive Flame
    onHitProcs =
      [ mkProc (skillDisplayName db (skName s)) rank rec p cd "hit" (mkSource (skName s) SrcSkill (skillDisplayName db (skName s)))
      | s <- charSkills c
      , not (excluded (skName s))
      , "records/skills/playerclass" `T.isPrefixOf` skName s
      , skLevel s > 0
      , Just rec <- [lookupRecord (skName s) db]
      , isOnHit rec
      , let rank = rankWith lv s
      , let p = maybe 1 (/ 100) (recNum rec "onHitActivationChance")
      , let cd = maybe 0 (atRank (rank - 1)) (HM.lookup "skillCooldownTime" rec)
      ]
```

`weaponRow` (the bare "Weapon Attack" baseline) mirrors `mkRow` with `mRank = Nothing`, `cdBase = 0` — no code changes beyond `mkRow`'s own rewrite above, since `weaponRow = mkRow "Weapon Attack" Nothing 100 0 []` already just calls it.

Finally, implement `attackDpsBreakdown`:

```haskell
attackDpsBreakdown :: GameDb -> [(Source, Record)] -> Character -> Text -> Maybe Int -> AttackKind -> Maybe AttackBreakdown
attackDpsBreakdown db sources c name rank kind =
  toBreakdown <$> find matches (attackDpsRows Nothing db sources c)
  where
    matches rd = adName (rdSummary rd) == name && adRank (rdSummary rd) == rank && adKind (rdSummary rd) == kind
    toBreakdown rd =
      AttackBreakdown
        { abName = adName (rdSummary rd)
        , abRank = adRank (rdSummary rd)
        , abKind = adKind (rdSummary rd)
        , abPerHit = adPerHit (rdSummary rd)
        , abDps = adDps (rdSummary rd)
        , abRate = adRate (rdSummary rd)
        , abSourcesByImpact = sortOn (negate . abs . siDpsImpact) (filter ((/= 0) . siDpsImpact) (map (impactOf rd) (rdSourcesTouched rd)))
        , abTypes = rdTypes rd
        , abRetaliation = rdRetaliation rd
        , abRateFactors = rdRateFactors rd
        , abTrigger = rdTrigger rd
        }
    impactOf rd s =
      let rowsWithout = attackDpsRows (Just (srcKey s)) db sources c
          dpsWithout = case find matches rowsWithout of
            Just rd' -> adDps (rdSummary rd')
            Nothing -> 0
       in SourceImpact s (adDps (rdSummary rd) - dpsWithout)
```

- [ ] **Step 5: Build and run the new tests**

Run: `stack build 2>&1 | tail -80`, fixing any remaining type errors (expect several rounds — `sibsOf`'s new `excluded` filter, `mkProc`'s new `grantedByLabel` parameter threading through its three call sites, `weaponRow`/`emitWps` needing `RowDetail` construction).

Run: `stack test --match "attackDpsBreakdown" 2>&1 | tail -60`
Expected: all five new tests pass. If `adName`/`skillDisplayName` fallback strings don't match what Step 1's tests assumed, fix the test literals to match the actual output (do not change `skillDisplayName`'s behavior).

- [ ] **Step 6: Run the full suite**

Run: `stack test 2>&1 | tail -20`
Expected: all examples pass, including every pre-existing test from Task 1's baseline.

- [ ] **Step 7: Commit**

```bash
git add src/GrimDawn/Report/Stats.hs test/GrimDawn/Report/StatsSpec.hs
git commit -m "$(cat <<'EOF'
Add attackDpsBreakdown: per-source DPS attribution for one attack row

Restructures attackDps's internals into attackDpsRows, a shared
computation that both attackDps (projects the existing summary) and
the new attackDpsBreakdown (projects per-source detail: flat/percent
contributors per damage type, a dedicated retaliation-added-to-attack
chain, attack-speed/cooldown-reduction/weapon-damage% rate factors,
proc trigger info, and a DPS-impact ranking per source) derive from,
so the two views can never disagree.
EOF
)"
```

---

### Task 3: JSON view (`GrimDawn.Web.View`)

**Files:**
- Modify: `src/GrimDawn/Web/View.hs`
- Test: `test/GrimDawn/Web/ViewSpec.hs`

**Interfaces:**
- Consumes: `attackDpsBreakdown`, `AttackBreakdown (..)`, `TypeDetail (..)`, `RetaliationDetail (..)`, `RetaliationTypeDetail (..)`, `RateFactorDetail (..)`, `TriggerDetail (..)`, `SourceImpact (..)`, `SourceAmount (..)`, `Source (..)`, `SourceCategory (..)` from `GrimDawn.Report.Stats`.
- Produces: `AttackBreakdownView (..)`, `attackBreakdownView :: GameDb -> [OwnedItem] -> [GearOverride] -> Difficulty -> Character -> Text -> Maybe Int -> AttackKind -> Maybe AttackBreakdownView`, exported from `GrimDawn.Web.View` for `GrimDawn.Web.Server` (Task 4) to call.

- [ ] **Step 1: Write the failing test**

Update the imports at the top of `test/GrimDawn/Web/ViewSpec.hs`: add `sortOn` to the `Data.List` import (`import Data.List (isInfixOf, sortOn)`) and `Skill (..)` to the `GrimDawn.Gdc` import (`import GrimDawn.Gdc (Character (..), Item (..), Skill (..))`).

Add a second character fixture to `test/GrimDawn/Web/ViewSpec.hs`, right after the existing `hero` definition — one equipped weapon (flat physical) plus an invested attack skill, so there's a real row to break down. This reuses the same `atk1.dbr` shape (`templateName` `skill_attack.tpl`, 100% weapon damage, 50 flat fire, 2s cooldown) already established as a fixture pattern in `test/GrimDawn/Report/StatsSpec.hs`:

```haskell
weapon :: Item
weapon = blankItem {itemBaseName = "records/items/weapon.dbr"}

heroWithAttack :: Character
heroWithAttack =
  hero
    { charEquipped = charEquipped hero ++ [weapon]
    , charSkills = [Skill "records/skills/playerclass01/atk1.dbr" 1 True 0 0 0 False False "" ""]
    }
```

Add the two extra records `weapon.dbr` and `atk1.dbr` to `synthDb`'s `gdbRecords` (in the existing `HM.fromList [...]` literal, alongside `records/items/helm.dbr`):

```haskell
          , ( "records/items/weapon.dbr"
            , HM.fromList
                [ ("Class", VString "WeaponMelee_Sword")
                , ("offensivePhysicalMin", VFloat 100)
                , ("offensivePhysicalMax", VFloat 100)
                ]
            )
          , ( "records/skills/playerclass01/atk1.dbr"
            , HM.fromList
                [ ("templateName", VString "database/templates/skill_attack.tpl")
                , ("weaponDamagePct", VFloat 100)
                , ("offensiveFireMin", VFloat 50)
                , ("offensiveFireMax", VFloat 50)
                , ("skillCooldownTime", VFloat 2)
                ]
            )
```

Add the new test group, after the existing `describe "setsView"` blocks:

```haskell
  describe "attackBreakdownView" $ do
    it "returns Nothing for an unknown attack name" $
      attackBreakdownView synthDb owned [] Ultimate heroWithAttack "Nonexistent" Nothing Active `shouldBe` Nothing

    it "encodes a known attack's breakdown with category strings and a sorted impact list" $ do
      case attackBreakdownView synthDb owned [] Ultimate heroWithAttack "Weapon Attack" Nothing Active of
        Nothing -> expectationFailure "expected a breakdown"
        Just abv -> do
          let json = BL.unpack (encode abv)
          ("\"kind\":\"active\"" `isInfixOf` json) `shouldBe` True
          ("\"category\":\"gear\"" `isInfixOf` json) `shouldBe` True
          let impacts = map (abs . sivDpsImpact) (abvSourcesByImpact abv)
          impacts `shouldBe` sortOn negate impacts -- sorted by |impact| descending
```

(`Weapon Attack` is the always-present bare baseline row — using it instead of `atk1`'s own display name sidesteps needing to know `skillDisplayName`'s exact fallback string for a record with no `skillDisplayName` field.)

- [ ] **Step 2: Confirm it fails to compile**

Run: `stack test 2>&1 | tail -40`
Expected: `Variable not in scope: attackBreakdownView`.

- [ ] **Step 3: Add the view types and `attackBreakdownView`**

Add to `src/GrimDawn/Web/View.hs`'s export list:

```haskell
  , SourceCategoryView
  , SourceContributionView (..)
  , TypeBreakdownView (..)
  , RetaliationTypeBreakdownView (..)
  , RetaliationBreakdownView (..)
  , RateFactorView (..)
  , TriggerView (..)
  , SourceImpactView (..)
  , AttackBreakdownView (..)
  , attackBreakdownView
```

Add `attackDpsBreakdown`, `AttackBreakdown (..)`, `TypeDetail (..)`, `RetaliationDetail (..)`, `RetaliationTypeDetail (..)`, `RateFactorDetail (..)`, `TriggerDetail (..)`, `SourceImpact (..)`, `SourceAmount (..)`, `Source (..)`, `SourceCategory (..)` to the existing `GrimDawn.Report.Stats` import list.

Add the view types and conversion functions, after `toAttackView` (which stays unchanged):

```haskell
-- | JSON text for a 'SourceCategory', plus the one synthetic value
-- ("retaliation") used only for the "Retaliation added to attack" flat line
-- within a 'TypeBreakdownView' (see 'retaliationPseudoSource' in
-- 'GrimDawn.Report.Stats') — not a real 'SourceCategory' constructor, since
-- it's a computed aggregate of several real sources, not one source.
type SourceCategoryView = Text

sourceCategoryView :: Source -> SourceCategoryView
sourceCategoryView s
  | srcKey s == "__retaliation__" = "retaliation"
  | otherwise = case srcCategory s of
      SrcGear -> "gear"
      SrcComponent -> "component"
      SrcAugment -> "augment"
      SrcSetBonus -> "setBonus"
      SrcDevotion -> "devotion"
      SrcMastery -> "mastery"
      SrcSkill -> "skill"
      SrcOther -> "other"

data SourceContributionView = SourceContributionView
  { scvLabel :: !Text
  , scvCategory :: !SourceCategoryView
  , scvValue :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON SourceContributionView where toJSON = genericToJSON opts

toContributionView :: SourceAmount -> SourceContributionView
toContributionView sa = SourceContributionView (srcLabel (saSource sa)) (sourceCategoryView (saSource sa)) (saValue sa)

data SourceImpactView = SourceImpactView
  { sivLabel :: !Text
  , sivCategory :: !SourceCategoryView
  , sivDpsImpact :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON SourceImpactView where toJSON = genericToJSON opts

toImpactView :: SourceImpact -> SourceImpactView
toImpactView si = SourceImpactView (srcLabel (siSource si)) (sourceCategoryView (siSource si)) (siDpsImpact si)

data TypeBreakdownView = TypeBreakdownView
  { tbvLabel :: !Text
  , tbvTotal :: !Double
  , tbvFlat :: ![SourceContributionView]
  , tbvFlatSubtotal :: !Double
  , tbvPercent :: ![SourceContributionView]
  , tbvTotalPercent :: !Double
  , tbvDurationPercent :: ![SourceContributionView]
  , tbvTotalDurationPercent :: !Double
  , tbvDamagePercent :: ![SourceContributionView]
  , tbvTotalDamagePercent :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON TypeBreakdownView where toJSON = genericToJSON opts

toTypeBreakdownView :: TypeDetail -> TypeBreakdownView
toTypeBreakdownView t =
  TypeBreakdownView
    { tbvLabel = tdLabel t
    , tbvTotal = tdTotal t
    , tbvFlat = map toContributionView (tdFlatSources t)
    , tbvFlatSubtotal = tdFlatSubtotal t
    , tbvPercent = map toContributionView (tdPercentSources t)
    , tbvTotalPercent = tdTotalPercent t
    , tbvDurationPercent = map toContributionView (tdDurationSources t)
    , tbvTotalDurationPercent = tdTotalDurationPercent t
    , tbvDamagePercent = map toContributionView (tdDamagePctSources t)
    , tbvTotalDamagePercent = tdTotalDamagePercent t
    }

data RetaliationTypeBreakdownView = RetaliationTypeBreakdownView
  { rtbvLabel :: !Text
  , rtbvFlat :: ![SourceContributionView]
  , rtbvFlatSubtotal :: !Double
  , rtbvPercent :: ![SourceContributionView]
  , rtbvTotalPercent :: !Double
  , rtbvRetaliationDamage :: !Double
  , rtbvAddedToAttack :: !Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON RetaliationTypeBreakdownView where toJSON = genericToJSON opts

toRetaliationTypeView :: RetaliationTypeDetail -> RetaliationTypeBreakdownView
toRetaliationTypeView t =
  RetaliationTypeBreakdownView
    { rtbvLabel = rtdLabel t
    , rtbvFlat = map toContributionView (rtdFlatSources t)
    , rtbvFlatSubtotal = rtdFlatSubtotal t
    , rtbvPercent = map toContributionView (rtdPercentSources t)
    , rtbvTotalPercent = rtdTotalPercent t
    , rtbvRetaliationDamage = rtdRetaliationDamage t
    , rtbvAddedToAttack = rtdAddedToAttack t
    }

data RetaliationBreakdownView = RetaliationBreakdownView
  { rbvAddToAttackPct :: ![SourceContributionView]
  , rbvTotalAddToAttackPct :: !Double
  , rbvByType :: ![RetaliationTypeBreakdownView]
  }
  deriving (Show, Eq, Generic)

instance ToJSON RetaliationBreakdownView where toJSON = genericToJSON opts

toRetaliationView :: RetaliationDetail -> RetaliationBreakdownView
toRetaliationView rd =
  RetaliationBreakdownView
    { rbvAddToAttackPct = map toContributionView (rdAddToAttackSources rd)
    , rbvTotalAddToAttackPct = rdTotalAddToAttackPct rd
    , rbvByType = map toRetaliationTypeView (rdByType rd)
    }

data RateFactorView = RateFactorView
  { rfvLabel :: !Text
  , rfvBase :: !Double
  , rfvContributions :: ![SourceContributionView]
  , rfvEffective :: !Double
  , rfvFormula :: !Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RateFactorView where toJSON = genericToJSON opts

toRateFactorView :: RateFactorDetail -> RateFactorView
toRateFactorView r = RateFactorView (rfdLabel r) (rfdBase r) (map toContributionView (rfdSources r)) (rfdEffective r) (rfdFormula r)

data TriggerView = TriggerView
  { trvChancePct :: !Double
  , trvCooldown :: !Double
  , trvGrantedBy :: !Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TriggerView where toJSON = genericToJSON opts

toTriggerView :: TriggerDetail -> TriggerView
toTriggerView t = TriggerView (trgChancePct t) (trgCooldown t) (trgGrantedBy t)

data AttackBreakdownView = AttackBreakdownView
  { abvName :: !Text
  , abvRank :: !(Maybe Int)
  , abvKind :: !Text
  , abvPerHit :: !Double
  , abvDps :: !Double
  , abvRate :: !Text
  , abvSourcesByImpact :: ![SourceImpactView]
  , abvTypes :: ![TypeBreakdownView]
  , abvRetaliation :: !(Maybe RetaliationBreakdownView)
  , abvRateFactors :: ![RateFactorView]
  , abvTrigger :: !(Maybe TriggerView)
  }
  deriving (Show, Eq, Generic)

instance ToJSON AttackBreakdownView where toJSON = genericToJSON opts

-- | The DPS attribution breakdown for one attack/proc row, identified by
-- name/rank/kind (matching an 'Attack'/'AttackDps' row already shown on the
-- character page). Mirrors 'detailView''s effective-sources construction so
-- the breakdown reflects the same what-if overrides/difficulty.
attackBreakdownView
  :: GameDb -> [OwnedItem] -> [GearOverride] -> Difficulty -> Character -> Text -> Maybe Int -> AttackKind -> Maybe AttackBreakdownView
attackBreakdownView db _owned overrides difficulty c name rank kind =
  toView <$> attackDpsBreakdown db sources c name rank kind
  where
    items = applyOverrides db overrides (equippedItems c)
    permanentBuffs = BuffToggle True False False
    nonSkill = statSources db items ++ devotionSources db c ++ masterySources db c
    extra = devotionSources db c ++ masterySources db c ++ skillSources permanentBuffs nonSkill db c
    sources = statSources db items ++ extra
    toView bd =
      AttackBreakdownView
        { abvName = abName bd
        , abvRank = abRank bd
        , abvKind = case abKind bd of Active -> "active"; Triggered -> "proc"
        , abvPerHit = abPerHit bd
        , abvDps = abDps bd
        , abvRate = abRate bd
        , abvSourcesByImpact = map toImpactView (abSourcesByImpact bd)
        , abvTypes = map toTypeBreakdownView (abTypes bd)
        , abvRetaliation = toRetaliationView <$> abRetaliation bd
        , abvRateFactors = map toRateFactorView (abRateFactors bd)
        , abvTrigger = toTriggerView <$> abTrigger bd
        }
```

- [ ] **Step 4: Build and run**

Run: `stack build 2>&1 | tail -60`, fix any errors.
Run: `stack test 2>&1 | tail -30`
Expected: all examples pass, including the new `attackBreakdownView` tests.

- [ ] **Step 5: Commit**

```bash
git add src/GrimDawn/Web/View.hs test/GrimDawn/Web/ViewSpec.hs
git commit -m "$(cat <<'EOF'
Add attackBreakdownView JSON encoding for the DPS attribution page

Mirrors detailView's effective-sources construction (overrides +
difficulty) so the breakdown reflects the same what-if gear
configuration as the rest of the character page.
EOF
)"
```

---

### Task 4: HTTP route (`GrimDawn.Web.Server`)

**Files:**
- Modify: `src-web/GrimDawn/Web/Server.hs`

**Interfaces:**
- Consumes: `attackBreakdownView`, `AttackKind (..)` from `GrimDawn.Web.View`/`GrimDawn.Report.Stats`; `parseOverrides`, `difficultyParam`, `findChar`, `loadOr` (all already defined in this file).

- [ ] **Step 1: Add the route**

In `src-web/GrimDawn/Web/Server.hs`, add `AttackKind (..)` to the `GrimDawn.Report.Stats` import and `attackBreakdownView` to the `GrimDawn.Web.View` import:

```haskell
import GrimDawn.Report.Stats (AttackKind (..), Difficulty (..), parseDifficulty)
import GrimDawn.Web.View (GearOverride (..), attackBreakdownView, craftableBlueprints, detailView, enhancementCatalog, rankEnhancements, rankItems, setsView, skillDictionary, summaryView)
```

Add a new route after the existing `/api/characters/:name/items` block (currently ending around line 155):

```haskell
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
```

Check `queryParamMaybe` is available from `Web.Scotty` in this codebase's scotty version (it's already imported wholesale via `import Web.Scotty`); if it isn't (older scotty exposes `param` differently), use the same `queryString <$> request` + manual `lookup "rank"` pattern `difficultyParam` already uses just above it in this file, decoding with `TE.decodeUtf8`/`readMaybe` instead.

- [ ] **Step 2: Build**

Run: `stack build 2>&1 | tail -60`
Expected: clean build.

- [ ] **Step 3: Manual smoke test**

Run: `stack exec gd-explorer -- serve --data-dir data/gd-data &` (or whatever the existing `serve` invocation is — check `README.md`/`app/Main.hs` for the exact command this project uses), then:

```bash
curl -s "http://localhost:PORT/api/characters/YOUR_CHARACTER_NAME/attack-breakdown?attack=Weapon%20Attack&kind=active" | head -c 2000
```

(substitute the actual port and a real character name from your save data). Expected: a JSON object with `name`, `perHit`, `dps`, `sourcesByImpact`, `types`, `rateFactors` fields populated with real numbers from your character's gear. Stop the server afterward (`kill %1` or Ctrl-C in its terminal).

- [ ] **Step 4: Commit**

```bash
git add src-web/GrimDawn/Web/Server.hs
git commit -m "$(cat <<'EOF'
Add /api/characters/:name/attack-breakdown route
EOF
)"
```

---

## Definition of done

- `stack build` and `stack test` both clean, `-Wall` with no new warnings.
- Every task's commit is in place.
- The manual smoke test in Task 4 Step 3 returns a populated `AttackBreakdown` JSON payload for a real character with at least one attack skill.
- Ready for the frontend plan (`docs/superpowers/plans/2026-07-03-dps-attribution-breakdown-frontend.md`) to consume this endpoint.
