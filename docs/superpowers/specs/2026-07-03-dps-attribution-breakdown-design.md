# Attack DPS estimate: source attribution breakdown

## Problem

The character page's "Attack DPS estimate" panel (`GrimDawn.Report.Stats.attackDps`)
shows each attack/proc row's total per-hit damage broken down **by damage
type**, but not by *source*. There's no way to see which piece of gear,
component, augment, devotion star, or skill/modifier is responsible for how
much of that number, or what would happen to it if a specific item were
swapped out. This makes the estimate hard to act on: you can see the total
changed after an edit, but not *why*.

## Goal

Clicking an attack or proc card navigates to a breakdown page for that one
row, showing:

1. **Which sources matter most** — an estimated DPS-impact ranking, so "what
   happens if I swap my boots" has a direct answer.
2. **The mechanics underneath** — per damage type, the flat and percentage
   contributions that produced the total, attributed to their source.

This is scoped to one attack/proc row at a time. The panel's "Estimated
total" (best attack + all procs) stays a plain sum and is not itself
clickable — merging the breakdowns of attacks you pick *between* would imply
they stack, which they don't.

## Source model

Every stat-contributing record used by `attackDps` is tagged with an owning
source when collected:

| Category    | Granularity                                                        | Example label            |
|-------------|---------------------------------------------------------------------|---------------------------|
| Gear        | One per equipped item (base+prefix+suffix+modifier+transmute)       | "Ring of the Whirlwind"  |
| Component   | An item's attached relic (relic + relic-bonus records)              | "Runebound Might"        |
| Augment     | An item's attached augment record                                   | "Attuned Skull"          |
| Set Bonus   | An active set-completion tier                                       | "Blood of Rihalla (3pc)" |
| Devotion    | An invested devotion star                                           | "Turtle"                 |
| Mastery     | A mastery training bar                                              | "Soldier"                |
| Skill       | An invested attack skill, and *each* invested transmuter/modifier separately | "Cadence", "Fighting Form" |

## Backend

### `Source` type and threading (`GrimDawn.Report.Stats`)

```haskell
data SourceCategory = SrcGear | SrcComponent | SrcAugment | SrcSetBonus
                     | SrcDevotion | SrcMastery | SrcSkill | SrcOther
  deriving (Show, Eq)

data Source = Source
  { srcKey      :: !Text            -- the record path (existing dedup key)
  , srcLabel    :: !Text            -- display label
  , srcCategory :: !SourceCategory
  }

instance Eq Source where a == b = srcKey a == srcKey b
instance Ord Source where compare a b = compare (srcKey a) (srcKey b)
```

`Eq`/`Ord` deferring to `srcKey` means every existing `nub`/`==`/list
comprehension over the old `[(Text, Record)]` keeps working unchanged once
the tuple's `fst` becomes `Source` instead of `Text`.

- `statSources`, `devotionSources`, `masterySources`, `skillSources` change
  from `[(Text, Record)]` to `[(Source, Record)]`, building the label at the
  point of construction (item display name via `itemAttrs`/`itemDisplayName`,
  devotion star name, mastery name, skill display name via
  `skillDisplayName`). Skill *siblings* (transmuters/modifiers folded in by
  `sibsOf`) each keep their own `Source` rather than collapsing into their
  parent's.
- Call sites into `GrimDawn.Item` (`sumField`, `sumRange`, `damageBonuses`,
  `damageTable`, `resistBonuses`, `characterBonuses`, `skillBonuses`) are
  untouched — they only ever pattern-match `(_, r)`, so callers pass
  `map (first srcKey) sources` at the boundary. `GrimDawn.Item` itself does
  not change.
- `renderStats`, `renderStatsDiff`, `mkScoreBase`, `scoreItems`,
  `findUpgrades` etc. update their type signatures to `[(Source, Record)]`
  but are otherwise unaffected (none of them display the key).

### Breakdown computation

`attackDps`'s output type (`[AttackDps]`, unattributed) doesn't change, so
nothing about the existing summary panel changes. Its `sources` parameter
naturally becomes `[(Source, Record)]` along with everything else it's built
from, but its body needs no logic changes — it never inspects a source
tuple's `fst` beyond structural equality (`nub`/`nubBy`), which `Source`'s
`Eq` instance preserves. A new function computes the attributed detail for
one row on demand, reusing the same per-row closures (`typedDamage`,
`mkRow`, `mkProc`, `emit`, `emitWps`) so the breakdown cannot silently drift
from the summary:

```haskell
attackDpsBreakdown
  :: GameDb -> [(Source, Record)] -> Character
  -> Text -> Maybe Int -> AttackKind    -- identifies the row: name, rank, kind
  -> Maybe AttackBreakdown
```

For the identified row:

- **Flat contributions** per damage type: `typedDamage` is restructured to
  compute each source's own flat pre-conversion amount (`sumRange [(srcKey s,
  r)] ... stem` per source, or the sib's own rank-indexed fields for
  skill/modifier sources), then apply the *same* aggregate conversion table
  to each source's vector independently. Conversion is a linear
  redistribution (fixed percentages, a single shared overflow-cap factor), so
  summing the per-source converted vectors reconstructs the existing
  aggregate exactly.
- **Percent contributions** per damage type: each source's own
  `offensive<Stem>Modifier` / `offensiveTotalDamageModifier` /
  `offensiveSlow<Stem>Modifier` field value, listed separately from the flat
  table (not merged into a single per-source DPS figure — see "Why flat and
  % stay separate" below).
- **Retaliation added to attack**: this is not a single opaque flat number —
  it's its own chained flat→%→% pipeline (`retalTotalOf` / `rdaGlobal` /
  `rdaFlat` in the current code) and gets a matching nested breakdown, since
  a retaliation/shield build lives or dies by which piece grants the flat
  retaliation stat versus which grants the "% of retaliation added to
  attack." Per damage type (only when nonzero):
  - **Retaliation flat** contributors — each source's own
    `retaliation<Stem>Min/Max` (e.g. a shield's "+50-80 Physical
    Retaliation"), summed to a subtotal.
  - **Retaliation % modifiers** contributors — each source's own
    `retaliation<Stem>Modifier` / `retaliationTotalDamageModifier`, summed
    and applied to the flat subtotal to give that type's total retaliation
    damage.
  - **% added to attack** contributors — each source's own
    `retaliationDamagePct` (global gear/skill sources, plus any sibling with
    its own value, e.g. the Reprisal transmuter). This percentage is a
    single scalar shared across every damage type on the row (the code
    applies the same `rdaPct` to every stem), so it's computed once and
    reused per type rather than repeated as separate contributor lists.
  - The type's total retaliation damage × the shared add-to-attack% is
    exactly the `rdaFlat` term that used to be an opaque single number. It
    now appears in that type's main **flat contributors** table as one
    line — `"Retaliation added to attack"`, tagged with a new `retaliation`
    source category — whose value is fully explained by this nested section
    (it's a computed aggregate of several real sources, not itself one
    source, so it isn't further splittable within the flat table; the
    nested section is where that split lives).
- **Rate factors**: attack-speed % (per source, for weapon%-based rows),
  cooldown-reduction % (per source, including chance-scaled resets like
  Reprisal), and weapon-damage % (per contributing skill/sibling), each as
  their own small contributor list. Procs report their granting source
  (single item/devotion/skill) plus trigger chance and base cooldown, not a
  contributor list (only one record ever grants a given proc).
- **DPS impact ranking**: for each source touching the row, recompute the
  row's `perHit`/`dps` with that source's `(Source, Record)` entries filtered
  out of the sources list (same formula, filtered input), and report
  `current - withoutSource`. This is the "if I swap out my boots" number.
  These deltas are computed independently against the same full baseline and
  are **not** required to sum to the row's total DPS — two sources with
  overlapping % bonuses each show their full individual impact, which
  double-counts the overlap if you were to add them together. That's
  expected for a marginal/counterfactual metric and is called out in the UI
  copy, not hidden. This recompute already cascades correctly through the
  retaliation pipeline above — removing a shield's flat retaliation stat, or
  removing Reprisal's add-to-attack %, changes `rdaFlat` (and therefore the
  row's DPS) exactly as it would in-game, with no special-casing needed.

### Known simplifications (carried over / new)

- Conversion/DoT-modifier percentages are aggregate values already summed
  across all relevant records before being listed per source (i.e. the *set*
  of contributing sources is per-source, but a single source's own
  conversion or DoT-duration field is what's shown — no further sub-split).

### Why flat and % stay separate (not one combined number)

A type's total is `flat_total × (1 + pct_total / 100)`. Flat contributions
are exactly additive: removing one flat source's contribution changes the
total by exactly that amount, and the source amounts sum to `flat_total`.
Percent contributions are *not* independently additive in DPS terms — the
"value" of one source's % bonus depends on how much flat damage and how many
other % bonuses are present. Trying to express a % source's contribution as
a single DPS number requires picking an arbitrary attribution order (or a
Shapley-value-style average over orders), which is more machinery than this
warrants and would produce numbers that don't reconcile with each other.
Showing flat amounts and percentage points as two separate, exact, additive
lists keeps every number on the page verifiable by hand. The DPS-impact
ranking (above) is the answer to "give me one number" — it's a distinct,
clearly-labeled counterfactual metric, not a decomposition.

## API

New endpoint, following the `rank` endpoint's pattern (query params for slot
overrides + difficulty):

```
GET /api/characters/:name/attack-breakdown
    ?kind=active&attack=Cadence&rank=12&item.0=...&comp.0=...&difficulty=elite
```

```ts
export type SourceCategory =
  | "gear" | "component" | "augment" | "setBonus"
  | "devotion" | "mastery" | "skill" | "retaliation" | "other";

export interface SourceContribution {
  label: string;
  category: SourceCategory;
  value: number; // flat amount, or percentage points, depending on table
}

export interface SourceImpact {
  label: string;
  category: SourceCategory;
  dpsImpact: number; // current dps - dps with this source's records removed
}

export interface TypeBreakdown {
  label: string;        // "Fire", "Vitality (dot)", ...
  total: number;         // matches Attack.types value for this label
  flat: SourceContribution[];
  flatSubtotal: number;
  percent: SourceContribution[];
  totalPercent: number;
}

export interface RateFactor {
  label: string;   // "Attack Speed" | "Cooldown Reduction" | "Weapon Damage %"
  base: number;
  contributions: SourceContribution[];
  effective: number;
  formula: string; // e.g. "1.0 x (1 + 42%) = 1.42/s"
}

// Retaliation damage's own flat -> % -> % chain for one damage type. Only
// present for types where the row has a nonzero retaliation contribution.
export interface RetaliationTypeBreakdown {
  label: string;                  // damage type, e.g. "Physical"
  flat: SourceContribution[];     // sources granting flat retaliation<Type>Min/Max
  flatSubtotal: number;
  percent: SourceContribution[];  // retaliation<Type>Modifier / retaliationTotalDamageModifier
  totalPercent: number;
  retaliationDamage: number;      // flatSubtotal x (1 + totalPercent/100)
  addedToAttack: number;          // retaliationDamage x totalAddToAttackPct/100 --
                                   // matches the "Retaliation added to attack" line
                                   // in this type's TypeBreakdown.flat
}

export interface RetaliationBreakdown {
  addToAttackPct: SourceContribution[]; // e.g. "Reprisal: +35%"; shared across all types
  totalAddToAttackPct: number;
  byType: RetaliationTypeBreakdown[];
}

export interface AttackBreakdown {
  name: string;
  rank: number | null;
  kind: "active" | "proc";
  perHit: number;
  dps: number;
  rate: string;
  sourcesByImpact: SourceImpact[]; // sorted by |dpsImpact| descending
  types: TypeBreakdown[];
  retaliation: RetaliationBreakdown | null; // null when the row has none
  rateFactors: RateFactor[];
  trigger: { chancePct: number; cooldown: number; grantedBy: string } | null; // procs only
}
```

`src/GrimDawn/Web/View.hs` gets the matching `AttackBreakdownView` /
`toAttackBreakdownView`, and `src-web/GrimDawn/Web/Server.hs` gets the new
route, mirroring how the existing `rank` endpoint is wired.

## Frontend

- `AttackCard` (in `CharacterDetailView.tsx`) becomes a link to
  `#/characters/:name/attacks/:kind:name:rank` (a single URL-encoded path
  segment combining kind/name/rank, since none of the three alone is a
  stable key — e.g. two different procs could share a name).
- New `AttackBreakdownView.tsx`, reading the same persisted per-character
  `overrides`/`difficulty` config from `localStorage` as the character page
  (no need to round-trip it through the URL), plus the route's kind/name/rank
  to call `getAttackBreakdown(...)`.
- Layout, top to bottom:
  1. Header — name, rank, kind badge, total per-hit/dps, rate description
     (same look as `AttackCard`).
  2. **"Sources ranked by DPS impact"** table — one row per source, sorted by
     `|dpsImpact|` descending, each showing its category badge and signed
     `~±N dps`. Brief caption noting these are independent counterfactuals
     and won't sum to the total.
  3. One section per damage type (only types present on the row) — two small
     tables (flat contributors, % contributors), each with a total/footer row
     that matches the type's `total`/`totalPercent`. The synthesized
     "Retaliation added to attack" flat line (when present) links down to
     section 4 rather than pretending to be one atomic source.
  4. **"Retaliation added to attack"** section — rendered only when
     `retaliation` is non-null. The shared "% added to attack" contributor
     table first (e.g. Reprisal), then one compact block per affected damage
     type: its flat contributors, % modifier contributors, and the resulting
     `flatSubtotal x (1+%) = retaliationDamage -> x addToAttack% =
     addedToAttack` line, so a shield build can see exactly which piece is
     carrying its retaliation damage and which skill/devotion is converting
     it into attack damage.
  5. **Rate** section — attack-speed/cooldown-reduction/weapon-damage%
     contributor tables, or the proc's trigger line, depending on `kind`.
  - Category badges (gear/component/augment/set/devotion/mastery/skill/
    retaliation) reuse `colorByType`-style styling conventions already in the
    codebase rather than introducing new color logic.
- Plain tables/lists throughout — consistent with the rest of the app, no new
  charting dependency.
- Back navigation to the character page (`#/characters/:name`).

## Testing

- `test/GrimDawn/Report/StatsSpec.hs`: extend the synthetic-item/skill
  fixtures already used for `attackDps` to cover `attackDpsBreakdown`:
  - Flat contributions from two different gear sources sum to the row's
    existing `flat_total` (cross-checked against `attackDps`'s own
    `adTypes` output on the same fixture).
  - A skill modifier (sibling) appears as its own `Source`, distinct from the
    primary skill.
  - Percent contributions list a gear source and a devotion source
    separately when both grant the same stat field.
  - DPS-impact: removing a source that contributes only flat damage produces
    a delta equal to that flat amount scaled by the row's existing total %
    (a directly computable expected value from the fixture).
  - Conversion linearity: a fixture with a type conversion produces per-source
    converted amounts that sum to the aggregate converted total.
  - Retaliation: a fixture with a flat-retaliation gear source, a
    retaliation-%-modifier source, and a separate %-added-to-attack source
    (mirroring the existing "attackDps adds retaliation damage to attack"
    fixture) produces a `RetaliationTypeBreakdown` whose `addedToAttack`
    matches the `rdaFlat` value that fixture already asserts on, and whose
    three contributor lists correctly separate the three sources.
- `test/GrimDawn/Web/ViewSpec.hs`: `toAttackBreakdownView` produces the
  expected JSON shape (category strings, sorted impact list) for a small
  fixture character.
- No existing test behavior changes — `attackDps`'s output and all specs
  asserting on it are unaffected by the `Source` type threading (only the
  unused `fst` component of the tuples changes shape).
