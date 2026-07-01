# Set view: transmute-eligible missing pieces

## Problem

Grim Dawn lets you sacrifice a copy of any set item to a blacksmith
transmutation recipe, which converts it into a random *other* item from the
same set. Given enough re-rolls (iron bits are cheap), owning a spare copy of
*any* piece in a set — or holding a blueprint for *any* piece in the set, since
you can just craft one — is enough to eventually fill in every missing piece
of that set.

The Sets view already flags a missing piece as "craftable" when you have a
blueprint for *that specific* item. It does not yet account for the broader
transmute path: excess duplicates elsewhere in the set, or a blueprint for a
*different* member of the set.

## Rule

A set is **transmutable** when either is true:

- **Excess**: total copies owned across all members of the set is greater
  than the number of distinct owned members (i.e. some piece has at least one
  spare copy beyond what's needed to complete the set).
- **Blueprint**: any member of the set — owned or not — has a learned
  blueprint.

When a set is transmutable, every *missing* member becomes transmute-eligible.

## Visual treatment

- Missing pieces with their own learned blueprint keep today's styling: dim
  fill, solid rarity-coloured border (`.item-square.craftable`).
- Missing pieces in a transmutable set that do **not** individually qualify as
  above get a new dotted rarity-coloured border (`.item-square.transmutable`).
  This is additive at the set level but skipped per-piece when the piece
  already shows the solid-border style, so each square gets exactly one
  distinguishing treatment.
- Scope: the sets grid (`ItemSquare` in `SetsView.tsx`) only. The detail
  preview panel's missing-item list is unchanged.

## Implementation

**Backend — `GrimDawn.Web.View`:**

- In `toSetView`, compute `setTransmutable :: Bool` once per set from
  `scMembers sc` and the existing `craftSet` blueprint map:
  - `anyExcess = sum (map smCount members) > length (filter smOwned members)`
  - `anyBlueprint = any (\m -> HM.member (smRecord m) craftSet) members`
  - `setTransmutable = anyExcess || anyBlueprint`
- Thread `setTransmutable` into `toMemberView`.
- Add `smvTransmutable :: !Bool` to `SetMemberView`, computed as
  `not (smOwned m) && setTransmutable && not craftableFlag`, where
  `craftableFlag` is the same expression already used for `smvCraftable`
  (hoisted into a `let` so both fields share it).

**Frontend:**

- `api.ts`: add `transmutable: boolean` to `SetMember`.
- `SetsView.tsx` `ItemSquare`: add a `transmutable` branch — only reachable
  when `!owned && !craftable` — that applies a `.transmutable` class with an
  inline `borderColor` (same rarity-colour lookup as `craftable` uses), and
  extends the tooltip text (e.g. "not owned — transmutable (duplicates or
  blueprint in set)").
- `styles.css`: add `.item-square.transmutable { background: #262a31; border:
  2px dotted; }`, mirroring `.craftable`'s solid-border rule but dotted.

## Testing

Extend the synthetic set fixture in `test/GrimDawn/Web/ViewSpec.hs` to cover:

- A set with a duplicate-owned member and a missing member → the missing
  member's `smvTransmutable` is `True`.
- A set with no duplicates but a learned blueprint for a *different* (owned)
  member → the missing member's `smvTransmutable` is `True`.
- A missing member that already has its own learned blueprint
  (`smvCraftable = True`) → `smvTransmutable` is `False` (no double-signal).
- A set with no duplicates and no blueprints → `smvTransmutable` is `False`
  for the missing member.

No new modules or CLI surface — this is confined to the existing
`GrimDawn.Web.View` set-view construction and the `SetsView.tsx` component.
