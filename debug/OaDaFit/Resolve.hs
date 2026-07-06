module OaDaFit.Resolve (resolveMatch) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.List (minimumBy)
import Data.Ord (comparing)

-- | Pick the candidate whose name matches @target@ (case-insensitive). With
-- several name-matches, choose the one whose @healthOf@ is closest to
-- @observedHealth@. 'Nothing' if no name matches.
resolveMatch
  :: (a -> Text)     -- ^ candidate's name
  -> (a -> Double)   -- ^ candidate's health in the relevant gear state
  -> Text            -- ^ target name from the data row
  -> Double          -- ^ observed health from the data row
  -> [a]
  -> Maybe a
resolveMatch nameOf healthOf target observedHealth candidates =
  case [c | c <- candidates, T.toLower (nameOf c) == T.toLower target] of
    [] -> Nothing
    [c] -> Just c
    cs -> Just (minimumBy (comparing (\c -> abs (healthOf c - observedHealth))) cs)
