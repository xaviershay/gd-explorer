-- | ANSI colouring for report output, matching Grim Dawn's in-game colours.
-- Colours are only emitted when explicitly enabled (the CLI enables them when
-- stdout is a terminal), so piped/redirected output stays plain text.
module GrimDawn.Report.Color
  ( rarityColor
  , typeColor
  , applyColor
  , colorByType
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | The ANSI colour for a rarity classification, matching Grim Dawn's in-game
-- item colours: Magical=yellow, Rare=green, Epic=blue, Legendary=purple.
-- Returns 'Nothing' for Common (rendered uncoloured) and unknown rarities.
rarityColor :: Text -> Maybe Text
rarityColor r = case T.toLower r of
  "magical" -> Just "\ESC[38;5;220m" -- yellow
  "rare" -> Just "\ESC[38;5;46m" -- green
  "epic" -> Just "\ESC[38;5;39m" -- blue
  "legendary" -> Just "\ESC[38;5;135m" -- purple
  _ -> Nothing

-- | The ANSI colour for a damage/resistance type, matching Grim Dawn's in-game
-- damage colours. Keyed by lowercase type name (the same vocabulary used for
-- both resistances and the trailing word of a damage bonus, e.g. \"Fire\").
-- Returns 'Nothing' for unknown types (rendered uncoloured).
typeColor :: Text -> Maybe Text
typeColor t = case T.toLower t of
  "physical" -> phys
  "trauma" -> phys -- Internal Trauma (DoT physical)
  "pierce" -> Just "\ESC[38;5;252m" -- light grey
  "fire" -> fire
  "burn" -> fire -- DoT fire
  "cold" -> cold
  "frostburn" -> cold -- DoT cold
  "lightning" -> lightning
  "electrocute" -> lightning -- DoT lightning
  "poison" -> poison
  "acid" -> poison -- immediate poison damage
  "aether" -> Just "\ESC[38;5;192m" -- pale yellow-green
  "chaos" -> Just "\ESC[38;5;88m" -- dark red
  "vitality" -> vitality
  "decay" -> vitality -- Vitality Decay (DoT vitality)
  "bleed" -> bleed
  "bleeding" -> bleed
  "elemental" -> Just "\ESC[38;5;159m" -- pale cyan
  _ -> Nothing
  where
    phys = Just "\ESC[38;5;250m" -- off-white
    fire = Just "\ESC[38;5;208m" -- orange
    cold = Just "\ESC[38;5;45m" -- light blue
    lightning = Just "\ESC[38;5;226m" -- yellow
    poison = Just "\ESC[38;5;70m" -- green
    vitality = Just "\ESC[38;5;127m" -- purple
    bleed = Just "\ESC[38;5;196m" -- red

ansiReset :: Text
ansiReset = "\ESC[0m"

-- | Wrap text in a colour when colouring is enabled and a colour is given;
-- otherwise return it unchanged.
applyColor :: Bool -> Maybe Text -> Text -> Text
applyColor True (Just c) txt = c <> txt <> ansiReset
applyColor _ _ txt = txt

-- | Colour a rendered resistance/damage entry by the first recognised damage
-- type word it contains (e.g. "Acid" in "32% Acid", "Burn" in "+30 Burn over 3s").
colorByType :: Bool -> Text -> Text
colorByType useColor s =
  case [c | w <- T.words s, Just c <- [typeColor w]] of
    (c : _) -> applyColor useColor (Just c) s
    [] -> s
