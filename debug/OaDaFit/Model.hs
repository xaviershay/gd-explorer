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
