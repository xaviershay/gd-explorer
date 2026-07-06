# OA / DA formula refinement — design

## Goal

Replace the current guessed Offensive Ability (OA) and Defensive Ability (DA)
totals in `Stats.hs` (`oaTotal`/`daTotal`) with a formula whose accuracy against
real in-game values is *measured*, not assumed. Build reusable tooling that lets
us compare candidate formulas objectively and rank them by fit, so future
refinements are cheap.

## Ground truth

`data.csv` — values read directly from the game, **known true**. One geared and
one ungeared row per character:

```
Character,OA,DA,Health,Energy,Gear
Shield,2187,2597,19369,2455,true
Shield,1831,2123,13154,2031,false
... (Adam, beats, stabby, Snake Eyes)
```

Five characters, deliberately different class mixes (Warlord, Purifier, Warder,
Nightblade, Witch Hunter) and levels (19, 25, 85, 100, 100). The save files under
`data/gd-data/save/main/` are the **geared** snapshots; the ungeared rows were
observed in-game with all gear removed.

Observation state (confirmed with user): **toggled/permanent auras on, no
temporary buffs or procs** — i.e. matches the app's `--buffs permanent`
classification. The formula must be evaluated in this buff state.

## Current model and its problems

`statSummary` (`src/GrimDawn/Report/Stats.hs`):

```haskell
oaTotal = (115 + 12*lvl + 0.4*Cunning + flatOA) * (1 + %OA/100)
daTotal = (115 + 12*lvl + 0.4*Spirit  + flatDA) * (1 + %DA/100)   -- Spirit is WRONG
```

Two confirmed defects:
1. **DA is derived from Spirit; it must be Physique** (official: +0.4 DA per
   Physique). This is the bulk of the "~1100 off" mystery in prior notes.
2. Per-level constant `12` and base `115` are guesses.

## Research findings (not trusted blindly — see below)

Official Grim Dawn guide / wiki:
- +10 OA and +10 DA per **character level**.
- +0.4 OA per Cunning, +0.4 DA per Physique.
- Level-1 base OA/DA constant: **not documented**.
- The published values are demonstrably **insufficient**: back-fitting the five
  geared observations (permanent buffs, DA→Physique) implies a per-level slope of
  ~15–17, not 10. Something scales with level beyond the +10.

**Leading hypothesis for the excess:** it is not really "per level". Higher-level
characters have far more mastery-bar and skill investment, which correlates with
level. The excess may be a **mastery/class contribution** the current model
misattributes. The harness must be able to test level vs. mastery/class as the
driver, since they are correlated in this dataset.

## Approach: a custom debug executable

A new standalone executable (NOT a `stack test` target) that reuses the library's
up-to-date computation path (`statSources`/`devotion`/`mastery`/`skillSources` +
`statSummary` helpers — the same code the View/JSON layer uses, per project
convention that the CLI text path is stale).

### Wiring

New `executables:` entry in `package.yaml`, e.g. `oa-da-fit`, `source-dirs: debug`,
depending on `gd-explorer` (+ `gd-explorer:web` only if a View function is reused),
`text`, `bytestring`/`cassava`-or-hand-split for reading `data.csv`. Reads the
same `data/gd-data` dir as the other tools.

### Per-character raw inputs it derives

For each character, in **two states** (geared, ungeared), with permanent buffs:

- `level`
- total attributes `Physique / Cunning / Spirit`
- `flatOA, %OA, flatDA, %DA` (from `keyTotalsOf` / `sumField`)
- class/mastery descriptors: the two mastery record names and their invested bar
  ranks (from `masterySources`), for the class-mix hypothesis.

**Geared** sources = `statSources db (charEquipped c)` + devotion + mastery +
`skillSources permanent nonSkill`. **Ungeared** sources = devotion + mastery +
`skillSources permanent (devotion+mastery)` — gear dropped, and buff ranks
recomputed without gear's `+skill` bonuses (this is how removing gear behaves
in-game). Reconstructing the ungeared state ourselves is what lets us use the
five ungeared rows as five additional ground-truth points **without asking the
user to record ungeared attributes**.

### Candidate formulas

A formula is a function `Inputs -> Double` for OA and for DA. Sweep a small,
explicit space along these dimensions:

- **base constant** `b` (fit or fixed)
- **per-level coefficient** `k` (fixed 10, or fit)
- **attribute coefficient** `a` (fixed 0.4, or fit; Cunning→OA, Physique→DA)
- **mastery/class term**: none, vs. a per-mastery-rank contribution `m * (bar
  ranks)`, vs. a per-class flat — to disentangle from `k`.
- **percent application**: `(base+level+attr+flat)*(1+%)` vs. `%` applied only to
  a subset. (Current code multiplies everything; verify.)

Coefficients that are "fit" are solved by least squares over all ten data points
(5 chars × 2 states) — closed-form linear regression, since every candidate is
linear in its parameters.

### Output and accuracy metric

For each candidate model, a table of predicted vs. observed OA and DA for all ten
data points, with residuals, plus aggregate **RMS error** and **max abs error**,
models ranked best-first. Because fitted models can overfit five characters, also
report **leave-one-character-out** error (fit on 4, predict the 5th) so we prefer
models that generalise, not just interpolate.

## How we establish "best" and when to run new experiments

1. Rank candidates by leave-one-out RMS (OA and DA separately).
2. If a clear winner drives residuals to near-zero (within a point or two — these
   are integers in-game), adopt it; update `oaTotal`/`daTotal`.
3. If two structurally-different models fit comparably (e.g. "high per-level" vs.
   "per-level 10 + mastery term") because level and mastery are collinear here,
   *that* is when we ask the user for **one** targeted experiment that breaks the
   collinearity — e.g. respec a mastery bar down, or record a character at two
   levels — chosen to be the single cheapest disambiguating observation. New
   experiments are a last resort, not the default.

## Deliverables

1. `debug/` executable `oa-da-fit` producing the ranked comparison report.
2. A chosen OA and DA formula, with its measured error, wired into
   `statSummary` (`oaTotal`/`daTotal`), including the DA→Physique fix.
3. Updated `[[gd-stats-and-factions]]` memory recording the validated formula and
   retiring the "OA/DA DEFERRED / ~1100 mystery" note.

## Out of scope

- The hit-chance (PTH) combat formula — only OA/DA magnitudes are in question.
- Temporary/proc buff states — we fit the permanent-buff state only.
- Frontend changes beyond the corrected totals already surfaced by the View path.
