# OA/DA Formula Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `oa-da-fit` debug executable that fits candidate Offensive/Defensive Ability formulas against the known-true `data.csv` values and ranks them by generalization error, then wire the winning formula into `statSummary`.

**Architecture:** A standalone Haskell exe reuses the library's stat-source machinery to reconstruct each character's geared and ungeared raw inputs (level, attributes, OA/DA flat & %, mastery ranks), joins them to `data.csv` ground truth, fits each candidate model by linear least squares, and reports per-model RMS + leave-one-character-out RMS. The winning formula's 8 constants (4 OA, 4 DA) are then substituted into `oaTotal`/`daTotal` in `Stats.hs`.

**Tech Stack:** Haskell, stack, hspec (existing test suite). No new dependencies — CSV is hand-split, the linear solver is hand-rolled Gaussian elimination.

## Global Constraints

- No new package dependencies. Read `data.csv` by splitting on commas; solve linear systems with a hand-written solver.
- Debug tooling computes through the **View/library path** (`GrimDawn.Report.Stats` `statSources`/`devotionSources`/`masterySources`/`skillSources`/`statSummary`), never the CLI text path.
- Evaluation buff state is **permanent only** — `parseBuffs "permanent"` (`BuffToggle True False False`).
- DA is derived from **Physique**, OA from **Cunning** (attribute coefficient applies Cunning→OA, Physique→DA).
- Data dir default: `data/gd-data`. Ground-truth file: `data.csv` at repo root.
- Exe name: `oa-da-fit`, source dir `debug/`.

---

### Task 1: Executable skeleton + `data.csv` parser

**Files:**
- Modify: `package.yaml` (add executable target)
- Create: `debug/Main.hs`
- Create: `debug/OaDaFit/Csv.hs`
- Test: `test/OaDaFit/CsvSpec.hs`
- Modify: `test/Spec.hs` (hspec-discover already? verify — if manual, register spec)

**Interfaces:**
- Produces: `data Obs = Obs { obsName :: Text, obsOA, obsDA, obsHealth, obsEnergy :: Double, obsGear :: Bool }` and `parseDataCsv :: Text -> [Obs]`.

- [ ] **Step 1: Add the executable target to `package.yaml`**

After the existing `gd-explorer` executable block (around line 84), add a sibling under `executables:`:

```yaml
    oa-da-fit:
        main: Main.hs
        source-dirs: debug
        ghc-options:
            - -threaded
            - -rtsopts
            - -with-rtsopts=-N
        dependencies:
            - gd-explorer
            - text
            - containers
```

- [ ] **Step 2: Check how the test suite discovers specs**

Run: `cat test/Spec.hs`
Expected: either `{-# OPTIONS_GHC -F -pgmF hspec-discover #-}` (auto-discovery — no registration needed) or an explicit `main` listing specs. If explicit, you will add `OaDaFit.CsvSpec` to it in later steps; if auto-discovery, new `*Spec.hs` files under `test/` are picked up automatically.

- [ ] **Step 3: Write the failing test**

Create `test/OaDaFit/CsvSpec.hs`:

```haskell
module OaDaFit.CsvSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import OaDaFit.Csv (Obs (..), parseDataCsv)

spec :: Spec
spec = describe "parseDataCsv" $ do
  let sample = T.unlines
        [ "Character,OA,DA,Health,Energy,Gear"
        , "Shield,2187,2597,19369,2455,true"
        , "Snake Eyes,2100,1988,13032,4055,true"
        , "Shield,1831,2123,13154,2031,false"
        ]
      rows = parseDataCsv sample
  it "parses one Obs per non-header line" $
    length rows `shouldBe` 3
  it "keeps names with spaces intact" $
    obsName (rows !! 1) `shouldBe` T.pack "Snake Eyes"
  it "parses numeric and boolean fields" $ do
    obsOA (head rows) `shouldBe` 2187
    obsDA (head rows) `shouldBe` 2597
    obsGear (head rows) `shouldBe` True
    obsGear (rows !! 2) `shouldBe` False
```

If `test/Spec.hs` is NOT hspec-discover, add `import qualified OaDaFit.CsvSpec` and a `describe`/`OaDaFit.CsvSpec.spec` entry to its `main`.

- [ ] **Step 4: Run the test to verify it fails**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'OaDaFit.Csv'`.

- [ ] **Step 5: Implement the parser**

Create `debug/OaDaFit/Csv.hs`:

```haskell
module OaDaFit.Csv
  ( Obs (..)
  , parseDataCsv
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | One row of ground-truth in-game values from data.csv.
data Obs = Obs
  { obsName :: !Text
  , obsOA :: !Double
  , obsDA :: !Double
  , obsHealth :: !Double
  , obsEnergy :: !Double
  , obsGear :: !Bool
  }
  deriving (Show, Eq)

-- | Parse data.csv. Header is dropped; blank lines skipped. Columns are
-- Character,OA,DA,Health,Energy,Gear split on commas (character names contain
-- no commas). Malformed rows are dropped.
parseDataCsv :: Text -> [Obs]
parseDataCsv t =
  [ o
  | line <- drop 1 (T.lines t)
  , not (T.null (T.strip line))
  , Just o <- [parseRow line]
  ]
  where
    parseRow line = case map T.strip (T.splitOn "," line) of
      [name, oa, da, hp, en, gear] ->
        Obs name
          <$> num oa <*> num da <*> num hp <*> num en
          <*> pure (gear == T.pack "true")
        & withName name
      _ -> Nothing
    -- reorder so name (non-Maybe) is applied first
    withName name mk = mk
    num = readMaybe . T.unpack
    (&) = flip ($)
```

Note the applicative shape: `Obs name <$> num oa <*> num da <*> num hp <*> num en <*> pure (...)` — `name` is a plain `Text` fed to the constructor, the four `num` calls are `Maybe Double`, the boolean is `pure`. Drop the `withName`/`&` helper if the direct expression compiles; it is written explicitly here:

```haskell
    parseRow line = case map T.strip (T.splitOn "," line) of
      [name, oa, da, hp, en, gear] ->
        Obs name <$> num oa <*> num da <*> num hp <*> num en
                 <*> Just (gear == T.pack "true")
      _ -> Nothing
    num = readMaybe . T.unpack
```

Use this second, cleaner `parseRow`/`num` form as the implementation.

- [ ] **Step 6: Create a minimal `debug/Main.hs` that reads the CSV**

```haskell
module Main (main) where

import qualified Data.Text.IO as TIO
import OaDaFit.Csv (parseDataCsv)

main :: IO ()
main = do
  raw <- TIO.readFile "data.csv"
  mapM_ (putStrLn . show) (parseDataCsv raw)
```

- [ ] **Step 7: Run the test to verify it passes and the exe builds**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: PASS (3 examples).
Run: `stack build oa-da-fit --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -5`
Expected: builds `oa-da-fit`.

- [ ] **Step 8: Commit**

```bash
git add package.yaml debug/Main.hs debug/OaDaFit/Csv.hs test/OaDaFit/CsvSpec.hs
git commit -m "Add oa-da-fit exe skeleton and data.csv parser"
```

---

### Task 2: Linear least-squares solver

**Files:**
- Create: `debug/OaDaFit/LeastSquares.hs`
- Test: `test/OaDaFit/LeastSquaresSpec.hs`

**Interfaces:**
- Produces: `leastSquares :: [[Double]] -> [Double] -> Maybe [Double]` — given design-matrix rows and targets, returns fitted coefficients (one per column) minimizing squared error, or `Nothing` if the normal-equations system is singular.

- [ ] **Step 1: Write the failing test**

Create `test/OaDaFit/LeastSquaresSpec.hs`:

```haskell
module OaDaFit.LeastSquaresSpec (spec) where

import Test.Hspec
import OaDaFit.LeastSquares (leastSquares)

spec :: Spec
spec = describe "leastSquares" $ do
  it "recovers exact coefficients for a consistent system" $ do
    -- y = 2 + 3*x ; columns are [1, x]
    let rows = [[1, 0], [1, 1], [1, 2], [1, 5]]
        ys   = [2, 5, 8, 17]
    case leastSquares rows ys of
      Just [b, k] -> do
        abs (b - 2) < 1e-9 `shouldBe` True
        abs (k - 3) < 1e-9 `shouldBe` True
      other -> expectationFailure ("expected [2,3], got " ++ show other)
  it "returns Nothing for a singular system" $
    -- two identical columns -> XtX singular
    leastSquares [[1, 1], [1, 1], [1, 1]] [1, 1, 1] `shouldBe` Nothing
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'OaDaFit.LeastSquares'`.

- [ ] **Step 3: Implement the solver**

Create `debug/OaDaFit/LeastSquares.hs`:

```haskell
module OaDaFit.LeastSquares
  ( leastSquares
  , solveLinear
  ) where

import Data.List (transpose)

-- | Ordinary least squares via the normal equations (XᵀX)β = Xᵀy.
-- Rows are observations, each a list of feature values (columns); ys are the
-- targets. Returns one coefficient per column, or Nothing if singular.
leastSquares :: [[Double]] -> [Double] -> Maybe [Double]
leastSquares rows ys = solveLinear xtx xty
  where
    cols = transpose rows           -- one list per feature
    xtx = [[dot a b | b <- cols] | a <- cols]
    xty = [dot a ys | a <- cols]
    dot u v = sum (zipWith (*) u v)

-- | Solve A x = b for a square A via Gaussian elimination with partial
-- pivoting. Returns Nothing if A is singular (pivot ~ 0).
solveLinear :: [[Double]] -> [Double] -> Maybe [Double]
solveLinear a b = go (zipWith (\row bi -> row ++ [bi]) a b)
  where
    n = length b
    go rows = eliminate 0 rows

    eliminate i rows
      | i >= n = Just (backSub rows)
      | otherwise =
          case pivotAt i rows of
            Nothing -> Nothing
            Just rows' ->
              let piv = rows' !! i
                  pivVal = piv !! i
                  reduce r
                    | otherwise =
                        let f = (r !! i) / pivVal
                         in zipWith (\rv pv -> rv - f * pv) r piv
                  rows'' =
                    [ if j == i then piv else reduce (rows' !! j)
                    | j <- [0 .. n - 1]
                    ]
               in eliminate (i + 1) rows''

    -- move a row with a non-negligible pivot in column i into position i
    pivotAt i rows =
      let (before, rest) = splitAt i rows
       in case break (\r -> abs (r !! i) > 1e-9) rest of
            (_, []) -> Nothing
            (skipped, chosen : others) ->
              Just (before ++ chosen : skipped ++ others)

    backSub rows =
      let solveRow i =
            let row = rows !! i
                rhs = row !! n
                known = sum [ (row !! j) * (xs !! j) | j <- [i + 1 .. n - 1] ]
             in (rhs - known) / (row !! i)
          xs = [ solveRow i | i <- [0 .. n - 1] ]
       in xs
```

Note: `backSub` is written with `xs` referring to itself for the already-solved higher indices; because Haskell is lazy and `solveRow i` only reads `xs !! j` for `j > i`, evaluate from the last row upward. If this self-reference proves fiddly, replace `backSub` with an explicit fold from `i = n-1` down to `0` accumulating a `Data.Map`/list. Prefer the explicit fold:

```haskell
    backSub rows = reverse (foldl step [] [n - 1, n - 2 .. 0])
      where
        step solvedDesc i =
          -- solvedDesc holds x[i+1..n-1] in descending-index order
          let row = rows !! i
              rhs = row !! n
              higher = zip [n - 1, n - 2 ..] solvedDesc
              known = sum [ (row !! j) * xj | (j, xj) <- higher ]
              xi = (rhs - known) / (row !! i)
           in solvedDesc ++ [xi]
```

Use the explicit-fold `backSub`. The final `reverse` restores ascending index order.

- [ ] **Step 4: Run the test to verify it passes**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add debug/OaDaFit/LeastSquares.hs test/OaDaFit/LeastSquaresSpec.hs
git commit -m "Add hand-rolled least-squares solver for oa-da-fit"
```

---

### Task 3: Per-character input extraction

**Files:**
- Create: `debug/OaDaFit/Inputs.hs`
- Test: `test/OaDaFit/InputsSpec.hs`

**Interfaces:**
- Consumes: `GrimDawn.Db.loadGameDb`, `GrimDawn.Aggregate.loadCharacters`, `GrimDawn.Report.Stats` (`statSources`, `devotionSources`, `masterySources`, `skillSources`, `statSummary`, `plainSources`, `parseBuffs`, `StatSummary(..)`), `GrimDawn.Item.sumField`, `GrimDawn.Gdc.Character(..)`/`Skill(..)`.
- Produces:
  - `data Inputs = Inputs { inName :: Text, inGeared :: Bool, inLevel, inPhys, inCun, inSpi, inFlatOA, inPctOA, inFlatDA, inPctDA, inMasteryRanks :: Double }`
  - `characterInputs :: GameDb -> Character -> Bool -> Inputs` (Bool = geared)
  - `loadInputs :: FilePath -> IO (GameDb, [Character])`

- [ ] **Step 1: Write the failing test (smoke test against real save data)**

Create `test/OaDaFit/InputsSpec.hs`:

```haskell
module OaDaFit.InputsSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.List (find)
import OaDaFit.Inputs (Inputs (..), characterInputs, loadInputs)
import GrimDawn.Gdc (Character (..))

spec :: Spec
spec = describe "characterInputs" $ do
  it "extracts Shield's geared level and attributes matching the app" $ do
    (db, chars) <- loadInputs "data/gd-data"
    case find ((== T.pack "Shield") . charName) chars of
      Nothing -> expectationFailure "no character named Shield"
      Just c -> do
        let g = characterInputs db c True
        inLevel g `shouldBe` 100
        round (inCun g) `shouldBe` (577 :: Int)
        round (inPhys g) `shouldBe` (1284 :: Int)
  it "ungeared Cunning is no greater than geared Cunning" $ do
    (db, chars) <- loadInputs "data/gd-data"
    case find ((== T.pack "Shield") . charName) chars of
      Just c ->
        inCun (characterInputs db c False) <= inCun (characterInputs db c True)
          `shouldBe` True
      Nothing -> expectationFailure "no Shield"
```

Note: `577`/`1284` are the permanent-buff geared attribute totals observed for Shield during design. If the app's numbers have legitimately changed, update these to the current `oa-da-fit`/`character` output rather than forcing them.

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'OaDaFit.Inputs'`.

- [ ] **Step 3: Implement extraction**

Create `debug/OaDaFit/Inputs.hs`:

```haskell
module OaDaFit.Inputs
  ( Inputs (..)
  , characterInputs
  , loadInputs
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.List (find)
import GrimDawn.Db (GameDb, loadGameDb)
import GrimDawn.Aggregate (loadCharacters)
import GrimDawn.Gdc (Character (..), Skill (..))
import GrimDawn.Item (sumField)
import GrimDawn.Report.Stats
  ( StatSummary (..)
  , statSummary
  , statSources
  , devotionSources
  , masterySources
  , skillSources
  , plainSources
  , parseBuffs
  , Difficulty (Normal)
  )

data Inputs = Inputs
  { inName :: !Text
  , inGeared :: !Bool
  , inLevel :: !Double
  , inPhys :: !Double
  , inCun :: !Double
  , inSpi :: !Double
  , inFlatOA :: !Double
  , inPctOA :: !Double
  , inFlatDA :: !Double
  , inPctDA :: !Double
  , inMasteryRanks :: !Double -- summed invested ranks across mastery bars
  }
  deriving (Show, Eq)

-- | Reconstruct one character's raw formula inputs in the permanent-buff state,
-- either geared (all equipped items) or ungeared (gear stripped). Ungeared
-- recomputes skill buff ranks without gear's +skill bonuses, matching how the
-- game behaves when gear is removed.
characterInputs :: GameDb -> Character -> Bool -> Inputs
characterInputs db c geared =
  Inputs
    { inName = charName c
    , inGeared = geared
    , inLevel = fromIntegral (charLevel c)
    , inPhys = attr (T.pack "Physique")
    , inCun = attr (T.pack "Cunning")
    , inSpi = attr (T.pack "Spirit")
    , inFlatOA = sumField src (T.pack "characterOffensiveAbility")
    , inPctOA = sumField src (T.pack "characterOffensiveAbilityModifier")
    , inFlatDA = sumField src (T.pack "characterDefensiveAbility")
    , inPctDA = sumField src (T.pack "characterDefensiveAbilityModifier")
    , inMasteryRanks = masteryRankTotal c
    }
  where
    perm = either error id (parseBuffs "permanent")
    gearSrc = if geared then statSources db (charEquipped c) else []
    dev = devotionSources db c
    mas = masterySources db c
    nonSkill = gearSrc ++ dev ++ mas
    sk = skillSources perm nonSkill db c
    src = plainSources (nonSkill ++ sk)
    summary = statSummary Normal c src
    attr label = maybe 0 snd (find ((== label) . fst) (ssAttributes summary))

-- | Total invested ranks across a character's mastery bars (the
-- @_classtraining_@ skill records).
masteryRankTotal :: Character -> Double
masteryRankTotal c =
  fromIntegral . sum $
    [ skLevel s
    | s <- charSkills c
    , T.pack "_classtraining_" `T.isInfixOf` skName s
    , skLevel s > 0
    ]

-- | Load the game DB and all characters from a data dir, dying on error.
loadInputs :: FilePath -> IO (GameDb, [Character])
loadInputs dir = do
  db <- loadGameDb dir >>= orDie
  chars <- loadCharacters dir >>= orDie
  pure (db, chars)
  where
    orDie = either (ioError . userError) pure
```

If `Difficulty(Normal)` is not exported from `GrimDawn.Report.Stats`, import it as `Difficulty (..)` — the module's export list already exposes `Difficulty (..)`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: PASS (2 examples). If Shield's attribute totals differ from 577/1284, update the test to the current values and note why in the commit.

- [ ] **Step 5: Commit**

```bash
git add debug/OaDaFit/Inputs.hs test/OaDaFit/InputsSpec.hs
git commit -m "Extract per-character OA/DA formula inputs (geared + ungeared)"
```

---

### Task 4: Candidate models, fitting, and metrics

**Files:**
- Create: `debug/OaDaFit/Model.hs`
- Test: `test/OaDaFit/ModelSpec.hs`

**Interfaces:**
- Consumes: `OaDaFit.Inputs.Inputs(..)`, `OaDaFit.Csv.Obs(..)`, `OaDaFit.LeastSquares.leastSquares`.
- Produces:
  - `data Ability = OA | DA`
  - `data ParamSpec = Free | Fixed Double`
  - `data Candidate = Candidate { cName :: String, cBase, cLevel, cAttr, cMastery :: ParamSpec }`
  - `data Point = Point { pInputs :: Inputs, pObserved :: Double }`
  - `fitCandidate :: Ability -> [Point] -> Candidate -> Maybe FitResult` where `data FitResult = FitResult { frBase, frLevel, frAttr, frMastery, frRms, frMaxAbs, frLooRms :: Double }`
  - `predict :: Ability -> FitResult -> Inputs -> Double`
  - `candidates :: [Candidate]`

- [ ] **Step 1: Write the failing test**

Create `test/OaDaFit/ModelSpec.hs`:

```haskell
module OaDaFit.ModelSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import OaDaFit.Inputs (Inputs (..))
import OaDaFit.Model

-- an Inputs with everything zero except the fields a test sets
zeroInputs :: Inputs
zeroInputs = Inputs (T.pack "x") True 0 0 0 0 0 0 0 0 0

spec :: Spec
spec = describe "fitCandidate" $ do
  it "recovers a known OA law: OA = 100 + 10*level + 0.4*cunning" $ do
    let mk lvl cun =
          let i = zeroInputs { inLevel = lvl, inCun = cun }
           in Point i (100 + 10 * lvl + 0.4 * cun)
        pts = [ mk 10 50, mk 50 200, mk 100 400, mk 25 600, mk 80 300 ]
        cand = Candidate "b+k*lvl+a*cun" Free Free Free (Fixed 0)
    case fitCandidate OA pts cand of
      Just fr -> do
        abs (frBase fr - 100) < 1e-6 `shouldBe` True
        abs (frLevel fr - 10) < 1e-6 `shouldBe` True
        abs (frAttr fr - 0.4) < 1e-6 `shouldBe` True
        frRms fr < 1e-6 `shouldBe` True
      Nothing -> expectationFailure "fit failed"
  it "applies the percent modifier outside the linear part" $ do
    -- observed = (base+...) * (1 + pct/100); with pct=10 the fit must undo it
    let i = zeroInputs { inLevel = 10, inPctOA = 10 }
        pts = [ Point i (110 * 1.10) -- base 10 + 10*lvl(=100) = 110, *1.1
              , Point (zeroInputs { inLevel = 20 }) 210 ]
        cand = Candidate "b+k*lvl" Free Free (Fixed 0) (Fixed 0)
    case fitCandidate OA pts cand of
      Just fr -> abs (frBase fr - 10) < 1e-6 `shouldBe` True
      Nothing -> expectationFailure "fit failed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'OaDaFit.Model'`.

- [ ] **Step 3: Implement models, fitting, metrics**

Create `debug/OaDaFit/Model.hs`:

```haskell
module OaDaFit.Model
  ( Ability (..)
  , ParamSpec (..)
  , Candidate (..)
  , Point (..)
  , FitResult (..)
  , fitCandidate
  , predict
  , candidates
  ) where

import Data.Text (Text)
import OaDaFit.Inputs (Inputs (..))
import OaDaFit.LeastSquares (leastSquares)

data Ability = OA | DA deriving (Eq, Show)

data ParamSpec = Free | Fixed Double deriving (Eq, Show)

-- A candidate law: predicted-before-percent =
--   base + level*inLevel + attr*(cunning|physique) + mastery*inMasteryRanks + flat
-- then multiplied by (1 + pct/100). Each coefficient is Free (fitted) or Fixed.
data Candidate = Candidate
  { cName :: !String
  , cBase :: !ParamSpec
  , cLevel :: !ParamSpec
  , cAttr :: !ParamSpec
  , cMastery :: !ParamSpec
  }
  deriving (Show)

data Point = Point { pInputs :: !Inputs, pObserved :: !Double }

data FitResult = FitResult
  { frBase :: !Double
  , frLevel :: !Double
  , frAttr :: !Double
  , frMastery :: !Double
  , frRms :: !Double
  , frMaxAbs :: !Double
  , frLooRms :: !Double
  }
  deriving (Show)

-- the ability-specific pieces of an Inputs
attrOf :: Ability -> Inputs -> Double
attrOf OA = inCun
attrOf DA = inPhys

flatOf :: Ability -> Inputs -> Double
flatOf OA = inFlatOA
flatOf DA = inFlatDA

pctOf :: Ability -> Inputs -> Double
pctOf OA = inPctOA
pctOf DA = inPctDA

-- feature value for each of the four coefficient slots
features :: Ability -> Inputs -> [Double]
features ab i = [1, inLevel i, attrOf ab i, inMasteryRanks i]

specs :: Candidate -> [ParamSpec]
specs (Candidate _ b k a m) = [b, k, a, m]

-- | Fit one candidate for one ability over the points, returning fitted
-- coefficients and error metrics. Free params are solved by least squares on
-- the percent-undone target; Fixed params contribute a known offset.
fitCandidate :: Ability -> [Point] -> Candidate -> Maybe FitResult
fitCandidate ab pts cand = do
  coeffs <- fitCoeffs ab pts cand
  let residual p =
        let i = pInputs p
         in predictWith ab coeffs i - pObserved p
      resids = map residual pts
      rms = sqrt (mean (map (^ (2 :: Int)) resids))
      maxAbs = maximum (0 : map abs resids)
  loo <- looRms ab pts cand
  pure FitResult
    { frBase = coeffs !! 0
    , frLevel = coeffs !! 1
    , frAttr = coeffs !! 2
    , frMastery = coeffs !! 3
    , frRms = rms
    , frMaxAbs = maxAbs
    , frLooRms = loo
    }

-- solve the free coefficients; return all four (fixed ones passed through)
fitCoeffs :: Ability -> [Point] -> Candidate -> Maybe [Double]
fitCoeffs ab pts cand =
  let sp = specs cand
      freeIdx = [ j | (j, Free) <- zip [0 ..] sp ]
      -- target with percent undone and fixed contributions subtracted
      target p =
        let i = pInputs p
            y0 = pObserved p / (1 + pctOf ab i / 100) - flatOf ab i
            fixedContribution =
              sum [ v * (features ab i !! j)
                  | (j, Fixed v) <- zip [0 ..] sp ]
         in y0 - fixedContribution
      designRow p = [ features ab (pInputs p) !! j | j <- freeIdx ]
      rows = map designRow pts
      ys = map target pts
   in if null freeIdx
        then Just (fixedValues sp)
        else do
          solved <- leastSquares rows ys
          pure (assemble sp freeIdx solved)
  where
    fixedValues = map (\s -> case s of Fixed v -> v; Free -> 0)
    assemble sp freeIdx solved =
      let table = zip freeIdx solved
       in [ case s of
              Fixed v -> v
              Free -> maybe 0 id (lookup j table)
          | (j, s) <- zip [0 ..] sp ]

-- predicted value from a full 4-coefficient vector
predictWith :: Ability -> [Double] -> Inputs -> Double
predictWith ab coeffs i =
  let linear = sum (zipWith (*) coeffs (features ab i)) + flatOf ab i
   in linear * (1 + pctOf ab i / 100)

-- | Predict from a FitResult.
predict :: Ability -> FitResult -> Inputs -> Double
predict ab fr = predictWith ab [frBase fr, frLevel fr, frAttr fr, frMastery fr]

-- leave-one-character-out RMS: for each distinct character name, fit on the
-- points of the other characters and predict this character's points.
looRms :: Ability -> [Point] -> Candidate -> Maybe Double
looRms ab pts cand =
  let names = distinct (map (inName . pInputs) pts)
      foldResiduals held =
        let train = [ p | p <- pts, inName (pInputs p) /= held ]
            test  = [ p | p <- pts, inName (pInputs p) == held ]
        in case fitCoeffs ab train cand of
             Nothing -> Nothing
             Just coeffs ->
               Just [ predictWith ab coeffs (pInputs p) - pObserved p | p <- test ]
      collected = traverse foldResiduals names
   in do
        rss <- collected
        let flat = concat rss
        pure (sqrt (mean (map (^ (2 :: Int)) flat)))

distinct :: Eq a => [a] -> [a]
distinct = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

mean :: [Double] -> Double
mean [] = 0
mean xs = sum xs / fromIntegral (length xs)

-- | The candidate law space to compare. Attribute coefficient is fixed at the
-- official 0.4 in most; a couple leave it free. The mastery term lets us test
-- whether the level excess is really mastery/class contribution.
candidates :: [Candidate]
candidates =
  [ Candidate "base+10lvl+0.4attr"          Free (Fixed 10) (Fixed 0.4) (Fixed 0)
  , Candidate "base+Klvl+0.4attr"           Free Free       (Fixed 0.4) (Fixed 0)
  , Candidate "base+Klvl+Aattr"             Free Free       Free        (Fixed 0)
  , Candidate "base+10lvl+0.4attr+Mmastery" Free (Fixed 10) (Fixed 0.4) Free
  , Candidate "base+Klvl+0.4attr+Mmastery"  Free Free       (Fixed 0.4) Free
  , Candidate "10lvl+0.4attr (no base)"     (Fixed 0) (Fixed 10) (Fixed 0.4) (Fixed 0)
  ]
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -20`
Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add debug/OaDaFit/Model.hs test/OaDaFit/ModelSpec.hs
git commit -m "Add candidate OA/DA models with least-squares fit and LOO metrics"
```

---

### Task 5: Wire the report and run it

**Files:**
- Modify: `debug/Main.hs`

**Interfaces:**
- Consumes: everything from Tasks 1, 3, 4.

- [ ] **Step 1: Replace `debug/Main.hs` with the full report**

```haskell
module Main (main) where

import Data.List (find, sortOn)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Text.Printf (printf)
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
        , Just c <- [find ((== obsName o) . charName') chars]
        , let inp = characterInputs db c (obsGear o)
        ]
  putStrLn "=== Offensive Ability ==="
  report OA (points OA)
  putStrLn ""
  putStrLn "=== Defensive Ability ==="
  report DA (points DA)
  where
    charName' = GrimDawn.Gdc.charName  -- see import note below

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
            (if inGeared i then "geared" else "ungeared")
            pr (pObserved p) (pr - pObserved p)
```

Import note: add `import GrimDawn.Gdc (charName)` and use `charName` directly instead of the `charName'` alias (the alias is shown only to flag that `Obs` and `Character` both need name access — resolve to a single `charName` import). Final imports for `Main.hs`:

```haskell
import GrimDawn.Gdc (charName)
```
and match `find ((== obsName o) . charName) chars`.

- [ ] **Step 2: Build and run the report**

Run:
```bash
stack build oa-da-fit --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -5
stack exec --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib oa-da-fit
```
Expected: two ranked tables (OA, DA), each ending with a BEST model, its coefficients, and a per-character predicted-vs-observed breakdown across all 10 points.

- [ ] **Step 3: Record the winning formulas**

Read the BEST lines for OA and DA. Note the four coefficients each (base, level, attr, mastery) and the LOO-RMS. Write them into the commit message. **Decision gate:** if the best OA and best DA both have LOO-RMS within a few points (in-game OA/DA are integers), proceed to Task 6. If two structurally different candidates tie (e.g. a high per-level coefficient vs. `10*level + mastery term`), STOP and report to the user — this is the collinearity case that needs one targeted experiment; do not guess.

- [ ] **Step 4: Commit**

```bash
git add debug/Main.hs
git commit -m "Add oa-da-fit ranked report; winning OA=<...> DA=<...> (see body)"
```

Fill the message body with the actual winning coefficients and LOO-RMS printed by the run.

---

### Task 6: Apply the winning formula to `statSummary`

**Files:**
- Modify: `src/GrimDawn/Report/Stats.hs` (`oaTotal`/`daTotal`, ~lines 693-701; possibly `Inputs` for mastery ranks)
- Test: `test/OaDaFit/GoldenSpec.hs`

**Interfaces:**
- Consumes: winning coefficients from Task 5.

- [ ] **Step 1: Write the failing golden test**

Create `test/OaDaFit/GoldenSpec.hs` asserting the app's computed OA/DA matches ground truth within tolerance. Use the same extraction the exe uses, but compute OA/DA through `statSummary` (`ssOaTotal`/`ssDaTotal`) so this tests the *shipped* formula, not the fitter:

```haskell
module OaDaFit.GoldenSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.List (find)
import qualified Data.Text.IO as TIO
import GrimDawn.Gdc (Character (..))
import GrimDawn.Report.Stats
  ( statSummary, statSources, devotionSources, masterySources
  , skillSources, plainSources, parseBuffs, Difficulty (Normal)
  , StatSummary (..) )
import OaDaFit.Csv (Obs (..), parseDataCsv)
import OaDaFit.Inputs (loadInputs)

-- tolerance: set from Task 5's max abs residual for the winning model, rounded
-- up. Replace TOL with that number (e.g. 5).
tol :: Double
tol = 5

spec :: Spec
spec = describe "shipped OA/DA formula vs ground truth" $
  it "matches data.csv within tolerance for every character/state" $ do
    raw <- TIO.readFile "data.csv"
    (db, chars) <- loadInputs "data/gd-data"
    let perm = either error id (parseBuffs "permanent")
        computed o = do
          c <- find ((== obsName o) . charName) chars
          let gearSrc = if obsGear o then statSources db (charEquipped c) else []
              nonSkill = gearSrc ++ devotionSources db c ++ masterySources db c
              src = plainSources (nonSkill ++ skillSources perm nonSkill db c)
              s = statSummary Normal c src
          pure (ssOaTotal s, ssDaTotal s)
        checks =
          [ (obsName o, obsGear o, oa, da, obsOA o, obsDA o)
          | o <- parseDataCsv raw
          , Just (oa, da) <- [computed o]
          ]
    mapM_ (\(nm, _, oa, da, eoa, eda) -> do
             abs (oa - eoa) <= tol `shouldBe` True
             abs (da - eda) <= tol `shouldBe` True)
          checks
```

Set `tol` to Task 5's winning max-abs residual, rounded up.

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -25`
Expected: FAIL — the current `oaTotal`/`daTotal` (base 115, per-level 12, DA-from-Spirit) miss ground truth well beyond `tol`.

- [ ] **Step 3: Rewrite `oaTotal`/`daTotal` with the winning coefficients**

In `src/GrimDawn/Report/Stats.hs`, replace the `oaTotal`/`daTotal` definitions (around lines 696-701). General form — substitute the eight fitted constants from Task 5 (`OA_BASE, OA_LVL, OA_ATTR, OA_MAST` and the DA equivalents), and note DA now uses **Physique**, not Spirit:

```haskell
    masteryRanks =
      fromIntegral . sum $
        [ skLevel s
        | s <- charSkills c
        , "_classtraining_" `T.isInfixOf` skName s
        , skLevel s > 0
        ] :: Double
    oaTotal =
      ( OA_BASE + OA_LVL * lvl + OA_ATTR * totalAttr "Cunning"
        + OA_MAST * masteryRanks
        + sumField sources "characterOffensiveAbility" )
        * (1 + sumField sources "characterOffensiveAbilityModifier" / 100)
    daTotal =
      ( DA_BASE + DA_LVL * lvl + DA_ATTR * totalAttr "Physique"
        + DA_MAST * masteryRanks
        + sumField sources "characterDefensiveAbility" )
        * (1 + sumField sources "characterDefensiveAbilityModifier" / 100)
```

If the winning model has a zero mastery coefficient (`*_MAST = 0`), drop the `masteryRanks` term and binding entirely for clarity. `charSkills`/`skName`/`skLevel` are already in scope via the `Character` argument `c` and the existing `GrimDawn.Gdc` import; confirm `skLevel`/`skName`/`charSkills` are imported (add to the `GrimDawn.Gdc` import list in Stats.hs if not).

- [ ] **Step 4: Update the stale code comment**

Replace the comment above `oaTotal` (currently `-- OA = (115 + 12*Level ...`) with the actual shipped formula and a note that it was fitted against `data.csv` (see `docs/superpowers/plans/2026-07-06-oa-da-formula.md`).

- [ ] **Step 5: Run the golden test to verify it passes**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -25`
Expected: PASS — every character/state within `tol` on both OA and DA.

- [ ] **Step 6: Run the full suite and a spot-check**

Run: `stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib 2>&1 | tail -15`
Expected: all specs pass (no regressions in existing stat tests).
Run: `stack exec --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib oa-da-fit`
Expected: report still consistent with the shipped constants.

- [ ] **Step 7: Commit**

```bash
git add src/GrimDawn/Report/Stats.hs test/OaDaFit/GoldenSpec.hs
git commit -m "Fit OA/DA totals to in-game data; fix DA to derive from Physique"
```

- [ ] **Step 8: Update memory**

Edit `[[gd-stats-and-factions]]`: replace the "OA/DA (DEFERRED)" / "~1100 mystery" paragraph with the validated formula (the eight constants, DA-from-Physique, permanent-buff basis, measured max error), and note the mystery was the missing per-level growth + the Spirit/Physique swap.

---

## Self-Review

**Spec coverage:**
- Debug exe on the View/library path → Tasks 1,3,4,5. ✓
- Uses all 10 points (geared + reconstructed ungeared) → Task 3 (`characterInputs` geared/ungeared), Task 5 (`points` over every Obs). ✓
- Candidate sweep incl. base/per-level/attr/percent-handling → Task 4 `candidates` + `predictWith` percent handling. ✓
- Class/mastery hypothesis → Task 4 mastery candidates + `inMasteryRanks`. ✓
- Ranking by leave-one-out → Task 4 `looRms`, Task 5 sort. ✓
- DA→Physique fix + permanent-buff state → Task 3 (`perm`), Task 6. ✓
- Deliverables: exe (Tasks 1-5), formula wired in (Task 6), memory update (Task 6 Step 8). ✓
- Decision gate for collinear tie → Task 5 Step 3. ✓

**Placeholder scan:** The only intentionally-deferred values are the eight fitted constants and `tol`, which are *outputs of Task 5* — every step names exactly where they come from and shows the surrounding code. No vague "add error handling" steps.

**Type consistency:** `Inputs`, `Obs`, `Point`, `Candidate`, `FitResult`, `Ability`, `ParamSpec` names are used identically across Tasks 3-6. `fitCandidate`/`fitCoeffs`/`predict`/`predictWith`/`looRms` signatures are consistent. `loadInputs`/`characterInputs` consumed unchanged in Tasks 5-6.
