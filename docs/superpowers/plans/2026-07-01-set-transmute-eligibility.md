# Set-view transmute eligibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flag missing set pieces as "transmute-eligible" (dotted border) in the Sets view when the set has excess duplicate copies of any member, or a learned blueprint for any member — distinct from the existing "individually craftable" (solid border) signal.

**Architecture:** Compute a per-set boolean (`setTransmutable`) once in `GrimDawn.Web.View.toSetView`, thread it into `toMemberView` to derive a new `smvTransmutable` field per member, expose it through the existing JSON view, and render it in the React `SetsView` component with a new CSS class.

**Tech Stack:** Haskell (GHC 9.10.3, hspec via `stack test`), TypeScript/React (Vite, `tsc --noEmit`).

## Global Constraints

- Rule (from spec `docs/superpowers/specs/2026-07-01-set-transmute-eligibility-design.md`): a set is transmutable when `sum(member copies) > count(distinct owned members)` (excess) OR any member (owned or not) has a learned blueprint.
- A missing member only gets the new dotted styling when it does NOT already qualify for the existing solid-border "individually craftable" styling (no double-signaling).
- Scope is the Sets grid (`ItemSquare` in `SetsView.tsx`) only — the set preview panel's missing-item list is unchanged.
- No new modules, no new CLI surface.

---

### Task 1: Backend — `smvTransmutable` field and set-level rule

**Files:**
- Modify: `src/GrimDawn/Web/View.hs:133-146` (`SetMemberView` record)
- Modify: `src/GrimDawn/Web/View.hs:179-208` (`toSetView`, `toMemberView`)
- Test: `test/GrimDawn/Web/ViewSpec.hs`

**Interfaces:**
- Consumes: `smCount`, `smOwned` from `GrimDawn.Report.Sets` (already imported at `src/GrimDawn/Web/View.hs:72-81`); `scMembers` from `SetCompletion`.
- Produces: `SetMemberView { ..., smvCraftable :: !Bool, smvTransmutable :: !Bool }`. Later (Task 2) frontend work reads `smvTransmutable` via the JSON field `transmutable`.

- [ ] **Step 1: Write the failing tests**

Open `test/GrimDawn/Web/ViewSpec.hs`. The existing fixture (`synthDb`, `owned`) defines a 2-member "Test Set" (`m1` owned once via `SharedStash`, `m2` missing). Add a new `describe` block after the existing `"setsView"` block (i.e. after the `it "encodes JSON with camelCase keys (prefix stripped)"` test, before `describe "detailView"`):

```haskell
  describe "setsView transmute eligibility" $ do
    it "leaves a missing member non-transmutable with no excess and no blueprints" $ do
      let [sv] = setsView synthDb [] owned
          [_, m2] = svMembers sv
      smvTransmutable m2 `shouldBe` False

    it "flags a missing member transmutable when another member has excess copies" $ do
      let dupOwned =
            [ OwnedItem blankItem {itemBaseName = "m1"} SharedStash
            , OwnedItem blankItem {itemBaseName = "m1"} SharedStash
            ]
          [sv] = setsView synthDb [] dupOwned
          [_, m2] = svMembers sv
      smvOwned m2 `shouldBe` False
      smvTransmutable m2 `shouldBe` True

    it "flags a missing member transmutable when a different set member has a learned blueprint" $ do
      let [sv] = setsView synthDb ["m1"] owned
          [_, m2] = svMembers sv
      smvCraftable m2 `shouldBe` False -- the blueprint is for m1, not m2
      smvTransmutable m2 `shouldBe` True

    it "does not double-signal a missing member that already has its own blueprint" $ do
      let [sv] = setsView synthDb ["m2"] owned
          [_, m2] = svMembers sv
      smvCraftable m2 `shouldBe` True
      smvTransmutable m2 `shouldBe` False
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `stack test :gd-explorer-test --test-arguments "--match \"setsView transmute eligibility\""`
Expected: compile error — `Variable not in scope: smvTransmutable`.

- [ ] **Step 3: Add the `smvTransmutable` field to `SetMemberView`**

In `src/GrimDawn/Web/View.hs`, change the `SetMemberView` record (currently lines 133-146) from:

```haskell
data SetMemberView = SetMemberView
  { smvName :: !Text
  , smvRecord :: !Text
  , smvOwned :: !Bool
  , smvCount :: !Int
  , smvHoldings :: ![HoldingView]
  , smvGear :: !GearView -- full in-game-style attributes (rarity, stats, ...)
  , smvSetTier :: !Int -- piece count this item activates (its 1-based position)
  , smvSetBonus :: !BonusGroupsView -- set bonus newly unlocked at that tier, by category
  , smvCraftable :: !Bool -- not owned, but a learned blueprint can craft it
  }
  deriving (Show, Eq, Generic)
```

to:

```haskell
data SetMemberView = SetMemberView
  { smvName :: !Text
  , smvRecord :: !Text
  , smvOwned :: !Bool
  , smvCount :: !Int
  , smvHoldings :: ![HoldingView]
  , smvGear :: !GearView -- full in-game-style attributes (rarity, stats, ...)
  , smvSetTier :: !Int -- piece count this item activates (its 1-based position)
  , smvSetBonus :: !BonusGroupsView -- set bonus newly unlocked at that tier, by category
  , smvCraftable :: !Bool -- not owned, but a learned blueprint can craft it
  , smvTransmutable :: !Bool -- not owned, no blueprint of its own, but the set
                             -- has excess copies elsewhere or a blueprint for
                             -- any member, so a re-rolled transmute can produce it
  }
  deriving (Show, Eq, Generic)
```

- [ ] **Step 4: Compute `setTransmutable` in `toSetView` and thread it through**

Change `toSetView` and `toMemberView` (currently lines 179-208) from:

```haskell
toSetView :: GameDb -> HM.HashMap Text () -> SetCompletion -> SetView
toSetView db craftSet sc =
  SetView
    { svName = scName sc
    , svRecord = scRecord sc
    , svOwnedCount = scOwnedCount sc
    , svTotal = scTotal sc
    , svComplete = scComplete sc
    , svLevel = case [l | Just l <- map (gvLevelRequirement . smvGear) members] of
        [] -> Nothing
        ls -> Just (maximum ls)
    , svMembers = members
    }
  where
    setRec = lookupRecord (scRecord sc) db
    members = zipWith (toMemberView db craftSet setRec) [1 ..] (scMembers sc)

toMemberView :: GameDb -> HM.HashMap Text () -> Maybe Record -> Int -> SetMember -> SetMemberView
toMemberView db craftSet setRec tier m =
  SetMemberView
    { smvName = smName m
    , smvRecord = smRecord m
    , smvOwned = smOwned m
    , smvCount = smCount m
    , smvHoldings = [HoldingView loc n | (loc, n) <- smHoldings m]
    , smvGear = toGearView (smRecord m) Nothing Nothing (itemAttrs (itemWithName (smRecord m)) db)
    , smvSetTier = tier
    , smvSetBonus = maybe emptyBonusGroups (tierBonusGroups db tier) setRec
    , smvCraftable = not (smOwned m) && HM.member (smRecord m) craftSet
    }
```

to:

```haskell
toSetView :: GameDb -> HM.HashMap Text () -> SetCompletion -> SetView
toSetView db craftSet sc =
  SetView
    { svName = scName sc
    , svRecord = scRecord sc
    , svOwnedCount = scOwnedCount sc
    , svTotal = scTotal sc
    , svComplete = scComplete sc
    , svLevel = case [l | Just l <- map (gvLevelRequirement . smvGear) members] of
        [] -> Nothing
        ls -> Just (maximum ls)
    , svMembers = members
    }
  where
    setRec = lookupRecord (scRecord sc) db
    members = zipWith (toMemberView db craftSet setRec setTransmutable) [1 ..] (scMembers sc)
    -- Transmutation sacrifices any copy of a set item for a random other item
    -- from the same set, so a spare copy of ANY member, or a learned blueprint
    -- for ANY member (owned or not, since you can just craft one), makes every
    -- missing member in the set transmute-eligible.
    setTransmutable =
      sum (map smCount (scMembers sc)) > length (filter smOwned (scMembers sc))
        || any (\mm -> HM.member (smRecord mm) craftSet) (scMembers sc)

toMemberView :: GameDb -> HM.HashMap Text () -> Maybe Record -> Bool -> Int -> SetMember -> SetMemberView
toMemberView db craftSet setRec setTransmutable tier m =
  SetMemberView
    { smvName = smName m
    , smvRecord = smRecord m
    , smvOwned = smOwned m
    , smvCount = smCount m
    , smvHoldings = [HoldingView loc n | (loc, n) <- smHoldings m]
    , smvGear = toGearView (smRecord m) Nothing Nothing (itemAttrs (itemWithName (smRecord m)) db)
    , smvSetTier = tier
    , smvSetBonus = maybe emptyBonusGroups (tierBonusGroups db tier) setRec
    , smvCraftable = craftableFlag
    , smvTransmutable = not (smOwned m) && setTransmutable && not craftableFlag
    }
  where
    craftableFlag = not (smOwned m) && HM.member (smRecord m) craftSet
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `stack test :gd-explorer-test --test-arguments "--match \"setsView\""`
Expected: PASS (all `setsView` and `setsView transmute eligibility` examples green).

- [ ] **Step 6: Run the full test suite**

Run: `stack test`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add src/GrimDawn/Web/View.hs test/GrimDawn/Web/ViewSpec.hs
git commit -m "$(cat <<'EOF'
Flag set-view missing pieces as transmute-eligible

A set member becomes transmutable when the set has excess duplicate
copies of any piece, or a learned blueprint for any piece, since either
lets you feed a transmutation reroll until it produces the missing item.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Frontend — dotted-border styling for transmute-eligible pieces

**Files:**
- Modify: `frontend/src/api.ts:16-26` (`SetMember` interface)
- Modify: `frontend/src/views/SetsView.tsx:128-159` (`ItemSquare`)
- Modify: `frontend/src/styles.css:126-135` (`.item-square` rules)

**Interfaces:**
- Consumes: `SetMemberView` JSON field `transmutable` produced by Task 1 (`smvTransmutable`, camelCase-stripped by the existing `dropPrefix`/`genericToJSON` machinery — no backend JSON-shape change needed beyond the new field).
- Produces: `.item-square.transmutable` CSS class; no other file depends on this.

- [ ] **Step 1: Add the `transmutable` field to the `SetMember` type**

In `frontend/src/api.ts`, change:

```typescript
export interface SetMember {
    name: string;
    record: string;
    owned: boolean;
    count: number;
    holdings: Holding[];
    gear: Gear;
    setTier: number;
    setBonus: BonusGroups;
    craftable: boolean; // not owned, but a learned blueprint can craft it
}
```

to:

```typescript
export interface SetMember {
    name: string;
    record: string;
    owned: boolean;
    count: number;
    holdings: Holding[];
    gear: Gear;
    setTier: number;
    setBonus: BonusGroups;
    craftable: boolean; // not owned, but a learned blueprint can craft it
    transmutable: boolean; // not owned; set has excess copies or a blueprint elsewhere
}
```

- [ ] **Step 2: Add the dotted-border CSS rule**

In `frontend/src/styles.css`, change:

```css
.item-square.missing {
    background: #262a31;
    border: 1px dashed #3a3f49;
}
/* Not owned but craftable from a known blueprint: dim fill with a solid
   rarity-coloured outline (colour set inline). */
.item-square.craftable {
    background: #262a31;
    border: 2px solid;
}
```

to:

```css
.item-square.missing {
    background: #262a31;
    border: 1px dashed #3a3f49;
}
/* Not owned but craftable from a known blueprint: dim fill with a solid
   rarity-coloured outline (colour set inline). */
.item-square.craftable {
    background: #262a31;
    border: 2px solid;
}
/* Not owned, no blueprint of its own, but the set as a whole can be
   transmuted into it (excess copies or a blueprint elsewhere in the set):
   dim fill with a dotted rarity-coloured outline (colour set inline). */
.item-square.transmutable {
    background: #262a31;
    border: 2px dotted;
}
```

- [ ] **Step 3: Render the new state in `ItemSquare`**

In `frontend/src/views/SetsView.tsx`, change:

```typescript
function ItemSquare({ member: m }: { member: SetMember }) {
  const owned = m.count > 0;
  const craftable = !owned && m.craftable;
  const tooltip =
    `${m.name}` +
    (m.gear.levelRequirement ? ` (lvl ${m.gear.levelRequirement})` : "") +
    `\n${
      owned
        ? `${m.count} owned: ` +
          m.holdings
            .map((h) => `${h.location}${h.count > 1 ? ` ×${h.count}` : ""}`)
            .join(", ")
        : craftable
          ? "not owned — craftable (blueprint known)"
          : "not owned"
    }`;
  return (
    <div
      className={"item-square" + (owned ? "" : craftable ? " craftable" : " missing")}
      style={
        owned
          ? { background: rarityColor(m.gear.classification) }
          : craftable
            ? { borderColor: rarityColor(m.gear.classification) }
            : undefined
      }
      title={tooltip}
    >
      {owned ? m.count : ""}
    </div>
  );
}
```

to:

```typescript
function ItemSquare({ member: m }: { member: SetMember }) {
  const owned = m.count > 0;
  const craftable = !owned && m.craftable;
  const transmutable = !owned && !craftable && m.transmutable;
  const tooltip =
    `${m.name}` +
    (m.gear.levelRequirement ? ` (lvl ${m.gear.levelRequirement})` : "") +
    `\n${
      owned
        ? `${m.count} owned: ` +
          m.holdings
            .map((h) => `${h.location}${h.count > 1 ? ` ×${h.count}` : ""}`)
            .join(", ")
        : craftable
          ? "not owned — craftable (blueprint known)"
          : transmutable
            ? "not owned — transmutable (duplicates or blueprint in set)"
            : "not owned"
    }`;
  return (
    <div
      className={
        "item-square" +
        (owned ? "" : craftable ? " craftable" : transmutable ? " transmutable" : " missing")
      }
      style={
        owned
          ? { background: rarityColor(m.gear.classification) }
          : craftable || transmutable
            ? { borderColor: rarityColor(m.gear.classification) }
            : undefined
      }
      title={tooltip}
    >
      {owned ? m.count : ""}
    </div>
  );
}
```

- [ ] **Step 4: Type-check the frontend**

Run: `cd frontend && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 5: Build the frontend**

Run: `cd frontend && npm run build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/api.ts frontend/src/views/SetsView.tsx frontend/src/styles.css
git commit -m "$(cat <<'EOF'
Show dotted border for transmute-eligible missing set pieces

Renders the new backend `transmutable` flag: a missing piece gets a
dotted rarity-coloured border when the set has excess duplicates or a
blueprint elsewhere, skipped when the piece already shows the solid
"individually craftable" border.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** excess rule (Task 1 Step 4), blueprint-anywhere rule (Task 1 Step 4), no-double-signal rule (Task 1 Step 4 `&& not craftableFlag`; Task 2 Step 3 `!craftable`), dotted styling (Task 2 Steps 2-3), sets-grid-only scope (no changes to `SetPreview`/preview panel). All covered.
- **Placeholder scan:** none found — every step has literal code and exact commands.
- **Type consistency:** `smvTransmutable` (Haskell) → JSON field `transmutable` (via existing `dropPrefix`) → `transmutable: boolean` (TypeScript) — verified consistent across both tasks.
