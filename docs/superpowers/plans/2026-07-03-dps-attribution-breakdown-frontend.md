# DPS Attribution Breakdown — Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each attack/proc card on the character page clickable, navigating to a new page that shows the full source-attributed breakdown for that one row: a "ranked by DPS impact" summary, per-damage-type flat/percent contributor tables, a dedicated retaliation-added-to-attack section, and rate factors (attack speed / cooldown reduction / weapon damage % / proc trigger info).

**Architecture:** A new `GET /api/characters/:name/attack-breakdown` endpoint (built in `docs/superpowers/plans/2026-07-03-dps-attribution-breakdown-backend.md`, which this plan depends on) returns the breakdown as JSON. The frontend adds a new hash route (`#/characters/:name/attacks/:key`), a new `AttackBreakdownView.tsx` page component, and a small set of presentational sub-components — all plain HTML tables styled to match the app's existing look, no new dependency.

**Tech Stack:** TypeScript/React (Vite), the project's existing hash-based router (`useHashRoute` in `frontend/src/hooks.ts`). This frontend has no unit test framework (`frontend/package.json` has no `test` script) — verification is `tsc --noEmit` (via `npm run build`) plus manual checking in a running dev server, matching how the rest of this app is built and per this project's standing instruction to verify UI changes in a browser before calling them done.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-03-dps-attribution-breakdown-design.md`. Backend plan: `docs/superpowers/plans/2026-07-03-dps-attribution-breakdown-backend.md` (must be complete first — this plan's Task 1 depends on the real `/api/characters/:name/attack-breakdown` JSON shape it produces).
- No new frontend dependencies (no charting library — plain tables/lists, per the design's approved "Structured tables/lists" choice).
- The breakdown page reads the same persisted per-character `overrides`/`difficulty` config (`localStorage`, key `gdx.charcfg.<name>`) the character page already uses, so it reflects whatever what-if gear is currently selected — it does not duplicate that state in the URL.
- `npm run build` (runs `tsc --noEmit` then `vite build`) must be clean after every task.

---

### Task 1: API types + `getAttackBreakdown` + expose the persisted config loader

**Files:**
- Modify: `frontend/src/api.ts`
- Modify: `frontend/src/views/CharacterDetailView.tsx:39-59` (`PersistedConfig`, `loadConfig` — add `export`)

**Interfaces:**
- Produces: `SourceCategory`, `SourceContribution`, `SourceImpact`, `TypeBreakdown`, `RetaliationTypeBreakdown`, `RetaliationBreakdown`, `RateFactor`, `Trigger`, `AttackBreakdown` (types), `getAttackBreakdown(name, kind, attack, rank, overrides?, difficulty?) => Promise<AttackBreakdown | null>` — all from `frontend/src/api.ts`, for Tasks 2-6 to consume. `PersistedConfig`, `loadConfig` exported from `frontend/src/views/CharacterDetailView.tsx`, for Task 3 to consume.

- [ ] **Step 1: Add the breakdown types and fetch function to `frontend/src/api.ts`**

Append to `frontend/src/api.ts`, after the existing `getItemRanking` function (end of file):

```typescript
// The DPS attribution breakdown for one attack/proc row, mirroring
// GrimDawn.Web.View.AttackBreakdownView.
export type SourceCategory =
    | "gear"
    | "component"
    | "augment"
    | "setBonus"
    | "devotion"
    | "mastery"
    | "skill"
    | "retaliation"
    | "other";

export interface SourceContribution {
    label: string;
    category: SourceCategory;
    value: number;
}

export interface SourceImpact {
    label: string;
    category: SourceCategory;
    dpsImpact: number;
}

export interface TypeBreakdown {
    label: string;
    total: number;
    flat: SourceContribution[];
    flatSubtotal: number;
    percent: SourceContribution[];
    totalPercent: number;
    durationPercent: SourceContribution[];
    totalDurationPercent: number;
    damagePercent: SourceContribution[];
    totalDamagePercent: number;
}

export interface RetaliationTypeBreakdown {
    label: string;
    flat: SourceContribution[];
    flatSubtotal: number;
    percent: SourceContribution[];
    totalPercent: number;
    retaliationDamage: number;
    addedToAttack: number;
}

export interface RetaliationBreakdown {
    addToAttackPct: SourceContribution[];
    totalAddToAttackPct: number;
    byType: RetaliationTypeBreakdown[];
}

export interface RateFactor {
    label: string;
    base: number;
    contributions: SourceContribution[];
    effective: number;
    formula: string;
}

export interface Trigger {
    chancePct: number;
    cooldown: number;
    grantedBy: string;
}

export interface AttackBreakdown {
    name: string;
    rank: number | null;
    kind: "active" | "proc";
    perHit: number;
    dps: number;
    rate: string;
    sourcesByImpact: SourceImpact[];
    types: TypeBreakdown[];
    retaliation: RetaliationBreakdown | null;
    rateFactors: RateFactor[];
    trigger: Trigger | null;
}

// Fetches the breakdown for one attack/proc row, identified by kind + name +
// (for skills) rank. Returns null when the backend has no matching row (404
// — e.g. the row's overrides/difficulty query no longer produces that attack)
// rather than throwing, so the page can render a clear "not found" state.
export async function getAttackBreakdown(
    name: string,
    kind: "active" | "proc",
    attack: string,
    rank: number | null,
    overrides: Overrides = {},
    difficulty: Difficulty = "ultimate",
): Promise<AttackBreakdown | null> {
    const qs = new URLSearchParams();
    qs.set("kind", kind);
    qs.set("attack", attack);
    if (rank !== null) qs.set("rank", String(rank));
    applyParams(qs, overrides, difficulty);
    const res = await fetch(
        `/api/characters/${encodeURIComponent(name)}/attack-breakdown?${qs.toString()}`,
    );
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`attack-breakdown: ${res.status} ${res.statusText}`);
    return res.json() as Promise<AttackBreakdown>;
}
```

- [ ] **Step 2: Export the persisted-config loader from `CharacterDetailView.tsx`**

In `frontend/src/views/CharacterDetailView.tsx`, add `export` to the two declarations (currently lines 39 and 44):

```typescript
export interface PersistedConfig {
    overrides: Overrides;
    difficulty: Difficulty;
    maxLevel: number | null;
}
```

```typescript
export function loadConfig(name: string): PersistedConfig | null {
```

(`saveConfig` and `STORAGE_PREFIX` stay private — the new page only reads the config, it never writes it, since gear what-ifs are only edited from the character page.)

- [ ] **Step 3: Type-check**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean (no `tsc` errors — these are additive changes, nothing consumes the new exports yet so no "unused" errors either, since TS doesn't flag unused exports by default).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api.ts frontend/src/views/CharacterDetailView.tsx
git commit -m "$(cat <<'EOF'
Add AttackBreakdown API types and getAttackBreakdown fetcher

Also exports CharacterDetailView's persisted per-character config
loader so the new breakdown page can read the same overrides/
difficulty the character page is currently showing.
EOF
)"
```

---

### Task 2: Route + clickable attack cards

**Files:**
- Modify: `frontend/src/App.tsx`
- Create: `frontend/src/attackKey.ts`
- Modify: `frontend/src/views/CharacterDetailView.tsx` (`AttacksPanel`, `AttackCard` — thread `name`, render as a link)

**Interfaces:**
- Consumes: `useHashRoute` (`frontend/src/hooks.ts`, unchanged), `Attack` (`frontend/src/api.ts`, unchanged).
- Produces: `encodeAttackKey(kind, name, rank): string`, `decodeAttackKey(key): { kind: "active" | "proc"; name: string; rank: number | null }` from `frontend/src/attackKey.ts`, consumed by both `CharacterDetailView.tsx` (to build the link) and `App.tsx`/`AttackBreakdownView.tsx` (Task 3, to parse the route).

- [ ] **Step 1: Add the attack-key codec**

Create `frontend/src/attackKey.ts`:

```typescript
// An attack/proc row's identity, as used both by the URL route
// (#/characters/:name/attacks/:key) and by the /attack-breakdown API query
// (kind/attack/rank params). Neither kind, name, nor rank alone is a stable
// key (e.g. two different procs can share a display name), so the three are
// joined with ":" and the whole thing URL-encoded — encoding first means any
// literal ":" in a skill's display name survives the round trip.
export function encodeAttackKey(
    kind: "active" | "proc",
    name: string,
    rank: number | null,
): string {
    return encodeURIComponent(`${kind}:${name}:${rank ?? ""}`);
}

export function decodeAttackKey(
    key: string,
): { kind: "active" | "proc"; name: string; rank: number | null } {
    const [kind, name, rankStr] = decodeURIComponent(key).split(":");
    return {
        kind: kind === "proc" ? "proc" : "active",
        name,
        rank: rankStr ? Number(rankStr) : null,
    };
}
```

- [ ] **Step 2: Add the route**

In `frontend/src/App.tsx`, add the import and a new match, checked *before* the existing character-detail match (whose `.+` group would otherwise also swallow `/attacks/...`):

```typescript
import { AttackBreakdownView } from "./views/AttackBreakdownView";
```

```typescript
function renderRoute(route: string) {
    const attackMatch = route.match(/^\/characters\/([^/]+)\/attacks\/(.+)$/);
    if (attackMatch) {
        const name = decodeURIComponent(attackMatch[1]);
        const key = attackMatch[2];
        return <AttackBreakdownView key={name + key} name={name} attackKey={key} />;
    }
    const charMatch = route.match(/^\/characters\/(.+)$/);
    if (charMatch) {
        const name = decodeURIComponent(charMatch[1]);
        return <CharacterDetailView key={name} name={name} />;
    }
    if (route.startsWith("/characters")) return <CharactersView />;
    if (route.startsWith("/components")) return <ComponentsView />;
    if (route.startsWith("/relics")) return <RelicsView />;
    return <SetsView />;
}
```

`AttackBreakdownView` doesn't exist yet — that's fine, Task 3 creates it; this task only needs it to *type-check* as a component accepting `{ name: string; attackKey: string }`, so create a minimal placeholder now (Task 3 replaces the body):

Create `frontend/src/views/AttackBreakdownView.tsx`:

```typescript
export function AttackBreakdownView({
    name,
    attackKey,
}: {
    name: string;
    attackKey: string;
}) {
    return (
        <p className="muted">
            Loading breakdown for {name} / {attackKey}…
        </p>
    );
}
```

- [ ] **Step 3: Make `AttackCard` a link**

In `frontend/src/views/CharacterDetailView.tsx`, thread `name` through `AttacksPanel` to `AttackCard` and render the card as an anchor. Update the call site (currently line 162):

```tsx
            <AttacksPanel attacks={c.attacks} name={name} />
```

Update `AttacksPanel`'s signature and its two `AttackCard` call sites (currently around lines 936-979):

```tsx
function AttacksPanel({ attacks, name }: { attacks: Attack[]; name: string }) {
    const active = attacks.filter((a) => a.kind === "active");
    const procs = attacks.filter((a) => a.kind === "proc");
    if (active.length === 0 && procs.length === 0) return null;

    const best = active.reduce((m, a) => Math.max(m, a.dps), 0);
    const procSum = procs.reduce((s, a) => s + a.dps, 0);

    return (
        <>
            <h2 className="section-head">Attack DPS estimate</h2>
            <p className="muted">
                Incorporates skills, devotions &amp; always-on buffs;
                conversions and stacking DoTs applied. Assumed base attack
                speed; no crit or enemy resistances. Click a card for a
                source-by-source breakdown.
            </p>
            {active.length > 0 && (
                <div className="attacks-total">
                    Best attack ~{num(best)}
                    {procSum > 0 && (
                        <>
                            {" "}
                            + procs ~{num(procSum)} ={" "}
                            <strong>~{num(best + procSum)} dps</strong>
                        </>
                    )}
                    {procSum === 0 && <strong> dps</strong>}
                </div>
            )}
            <div className="attack-grid">
                {active.length > 0 && (
                    <div className="attacks-sub">Attacks (pick one)</div>
                )}
                {active.map((a, i) => (
                    <AttackCard key={i} a={a} name={name} />
                ))}
                {procs.length > 0 && (
                    <div className="attacks-sub">
                        Procs (auto, while attacking)
                    </div>
                )}
                {procs.map((a, i) => (
                    <AttackCard key={i} a={a} name={name} />
                ))}
            </div>
        </>
    );
}
```

Update `AttackCard` (currently around lines 985-1015) to render as a link:

```tsx
function AttackCard({ a, name }: { a: Attack; name: string }) {
    const href = `#/characters/${encodeURIComponent(name)}/attacks/${encodeAttackKey(a.kind, a.name, a.rank)}`;
    return (
        <a className="attack-card" href={href}>
            <div className="attack-row">
                <span className="attack-name">
                    {a.name}
                    {a.rank != null && (
                        <span className="muted"> ({a.rank})</span>
                    )}
                </span>
                <span className="attack-dps">
                    {num(a.dps)} <span className="muted">dps</span>
                </span>
            </div>
            <div className="attack-meta muted">
                per-hit {num(a.perHit)} · {a.rate}
            </div>
            <div className="attack-types">
                {a.types.map((t, i) => (
                    <span
                        key={i}
                        className="dtype"
                        style={{ color: elementColor(t.label) }}
                    >
                        {t.label} {num(t.value)}
                    </span>
                ))}
            </div>
        </a>
    );
}
```

Add the import at the top of `frontend/src/views/CharacterDetailView.tsx`:

```typescript
import { encodeAttackKey } from "../attackKey";
```

Add a matching CSS rule so the card doesn't inherit default anchor styling — see Task 7 (styles.css) for the full set; for now add just this one rule to `frontend/src/styles.css` right after the existing `.attack-card { ... }` block:

```css
a.attack-card {
    display: block;
    text-decoration: none;
    color: inherit;
    cursor: pointer;
}
a.attack-card:hover {
    border-color: var(--muted);
}
```

- [ ] **Step 4: Type-check and manually verify the link**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean.

Run: `cd frontend && npm run dev` (leave running), open the app in a browser, navigate to a character with at least one attack skill, and click an attack card. Expected: the URL changes to `#/characters/<name>/attacks/<encoded-key>` and the page shows the Task 2 placeholder text ("Loading breakdown for..."). Stop the dev server afterward.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/App.tsx frontend/src/attackKey.ts frontend/src/views/AttackBreakdownView.tsx frontend/src/views/CharacterDetailView.tsx frontend/src/styles.css
git commit -m "$(cat <<'EOF'
Route attack/proc cards to a per-row breakdown page

Adds #/characters/:name/attacks/:key, where :key encodes kind+name+
rank (the only stable identity for a row — two procs can share a
display name). AttackBreakdownView is a placeholder here; it's built
out in the following tasks.
EOF
)"
```

---

### Task 3: `AttackBreakdownView` — data loading, header, sources-by-impact table

**Files:**
- Modify: `frontend/src/views/AttackBreakdownView.tsx`
- Modify: `frontend/src/styles.css`

**Interfaces:**
- Consumes: `getAttackBreakdown`, `AttackBreakdown`, `SourceImpact` (Task 1); `decodeAttackKey` (Task 2); `loadConfig` (Task 1, from `CharacterDetailView.tsx`); `useAsync`/`useAsyncKeep` (`frontend/src/hooks.ts`, unchanged).
- Produces: the page's overall shape — later tasks (4-6) fill in `<TypeSection>`, `<RetaliationSection>`, `<RateFactorBlock>`/`<TriggerBlock>` as siblings inside this same component, reading fields off the same `AttackBreakdown` object this task fetches.

- [ ] **Step 1: Replace the placeholder with real data loading + header + impact table**

Replace the whole contents of `frontend/src/views/AttackBreakdownView.tsx`:

```tsx
import { getAttackBreakdown, SourceCategory, SourceImpact } from "../api";
import { useAsync } from "../hooks";
import { loadConfig } from "./CharacterDetailView";
import { decodeAttackKey } from "../attackKey";

const num = (n: number) => Math.round(n).toLocaleString();

// Human label + a fixed colour per source category, shared by every table on
// this page (impact ranking, flat/percent contributors, rate factors).
const CATEGORY_LABEL: Record<SourceCategory, string> = {
    gear: "Gear",
    component: "Component",
    augment: "Augment",
    setBonus: "Set Bonus",
    devotion: "Devotion",
    mastery: "Mastery",
    skill: "Skill",
    retaliation: "Retaliation",
    other: "Other",
};

const CATEGORY_COLOR: Record<SourceCategory, string> = {
    gear: "#5a9bff",
    component: "#4caf50",
    augment: "#d4c84a",
    setBonus: "#b56cff",
    devotion: "#ff8a3a",
    mastery: "#ff5a7a",
    skill: "#43d1c9",
    retaliation: "#c9c9c9",
    other: "#9a9a9a",
};

export function CategoryBadge({ category }: { category: SourceCategory }) {
    return (
        <span
            className="category-badge"
            style={{ color: CATEGORY_COLOR[category] }}
        >
            {CATEGORY_LABEL[category]}
        </span>
    );
}

export function AttackBreakdownView({
    name,
    attackKey,
}: {
    name: string;
    attackKey: string;
}) {
    const { kind, name: attackName, rank } = decodeAttackKey(attackKey);
    const cfg = loadConfig(name);
    const overrides = cfg?.overrides ?? {};
    const difficulty = cfg?.difficulty ?? "ultimate";

    const state = useAsync(
        () => getAttackBreakdown(name, kind, attackName, rank, overrides, difficulty),
        `attack-breakdown:${name}:${attackKey}:${difficulty}:${JSON.stringify(overrides)}`,
    );

    const backHref = `#/characters/${encodeURIComponent(name)}`;

    if (state.status === "error")
        return <p className="error">{state.error}</p>;
    if (state.status === "loading")
        return <p className="muted">Loading breakdown…</p>;
    if (!state.data)
        return (
            <>
                <p className="error">
                    No matching attack/proc row found — it may no longer
                    apply under the current gear configuration.
                </p>
                <a href={backHref}>&larr; Back to {name}</a>
            </>
        );

    const bd = state.data;

    return (
        <div className="breakdown-page">
            <a className="breakdown-back" href={backHref}>
                &larr; Back to {name}
            </a>
            <h1 className="breakdown-title">
                {bd.name}
                {bd.rank != null && (
                    <span className="muted"> ({bd.rank})</span>
                )}
                <span className="muted">
                    {" "}
                    — {bd.kind === "proc" ? "proc" : "attack"}
                </span>
            </h1>
            <div className="breakdown-summary">
                <span className="breakdown-dps">
                    {num(bd.dps)} <span className="muted">dps</span>
                </span>
                <span className="muted">
                    per-hit {num(bd.perHit)} · {bd.rate}
                </span>
            </div>

            <ImpactSection sources={bd.sourcesByImpact} />
        </div>
    );
}

function ImpactSection({ sources }: { sources: SourceImpact[] }) {
    if (sources.length === 0) return null;
    return (
        <>
            <h2 className="section-head">Sources ranked by DPS impact</h2>
            <p className="muted">
                Each row is an independent counterfactual — this attack's DPS
                with vs. without that one source, holding everything else
                fixed. Rows won't necessarily sum to the total above:
                overlapping percentage bonuses each show their full
                individual impact.
            </p>
            <table className="contrib-table impact-table">
                <thead>
                    <tr>
                        <th>Source</th>
                        <th>Category</th>
                        <th className="num-col">DPS impact</th>
                    </tr>
                </thead>
                <tbody>
                    {sources.map((s, i) => (
                        <tr key={i}>
                            <td>{s.label}</td>
                            <td>
                                <CategoryBadge category={s.category} />
                            </td>
                            <td className="num-col">
                                {s.dpsImpact >= 0 ? "+" : ""}
                                {num(s.dpsImpact)}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </>
    );
}
```

- [ ] **Step 2: Add base page/table styles**

Add to `frontend/src/styles.css`, after the existing "Attack DPS" section:

```css
/* Attack breakdown page */
.breakdown-back {
    display: inline-block;
    margin-bottom: 10px;
    color: var(--muted);
}
.breakdown-title {
    font-size: 20px;
    margin: 0 0 6px;
}
.breakdown-summary {
    display: flex;
    align-items: baseline;
    gap: 14px;
    margin-bottom: 6px;
}
.breakdown-dps {
    font-size: 22px;
    font-weight: 700;
    color: #ffce3a;
    font-variant-numeric: tabular-nums;
}
.category-badge {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
}
.contrib-table {
    border-collapse: collapse;
    font-size: 13px;
    font-variant-numeric: tabular-nums;
    width: 100%;
    max-width: 640px;
    margin-bottom: 10px;
}
.contrib-table th {
    color: var(--muted);
    font-weight: 700;
    font-size: 11px;
    text-align: left;
    padding: 0 10px 3px 0;
    border-bottom: 1px solid var(--border);
}
.contrib-table td {
    padding: 3px 10px 3px 0;
}
.contrib-table tr + tr td {
    border-top: 1px solid rgba(255, 255, 255, 0.04);
}
.contrib-table .num-col {
    text-align: right;
}
.contrib-table tfoot td {
    border-top: 1px solid var(--border);
    font-weight: 700;
}
```

- [ ] **Step 3: Type-check and manually verify**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean.

Run: `cd frontend && npm run dev`, open a character with an attack skill, click a card. Expected: the breakdown page loads with a title, dps/per-hit/rate line, and (if the character has more than one contributing source, e.g. any gear/devotion beyond the bare weapon) a "Sources ranked by DPS impact" table. Stop the dev server afterward.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/views/AttackBreakdownView.tsx frontend/src/styles.css
git commit -m "$(cat <<'EOF'
Add AttackBreakdownView data loading, header, and impact ranking

Reads the character's persisted overrides/difficulty (same as the
character page) so the breakdown reflects the currently selected
what-if gear.
EOF
)"
```

---

### Task 4: Per-damage-type sections

**Files:**
- Modify: `frontend/src/views/AttackBreakdownView.tsx`
- Modify: `frontend/src/styles.css`

**Interfaces:**
- Consumes: `TypeBreakdown`, `SourceContribution` (Task 1); `CategoryBadge` (Task 3, same file).

- [ ] **Step 1: Add the per-type sections**

In `frontend/src/views/AttackBreakdownView.tsx`, add `TypeBreakdown` and `SourceContribution` to the `../api` import, and render a `<TypeSection>` per entry in `bd.types` after `<ImpactSection ... />` in `AttackBreakdownView`'s returned JSX:

```tsx
            <ImpactSection sources={bd.sourcesByImpact} />

            {bd.types.map((t, i) => (
                <TypeSection key={i} t={t} />
            ))}
```

Add the component (after `ImpactSection`):

```tsx
function ContribTable({
    rows,
    valueLabel,
    total,
}: {
    rows: SourceContribution[];
    valueLabel: string;
    total: number;
}) {
    if (rows.length === 0) return null;
    return (
        <table className="contrib-table">
            <thead>
                <tr>
                    <th>Source</th>
                    <th>Category</th>
                    <th className="num-col">{valueLabel}</th>
                </tr>
            </thead>
            <tbody>
                {[...rows]
                    .sort((a, b) => Math.abs(b.value) - Math.abs(a.value))
                    .map((r, i) => (
                        <tr key={i}>
                            <td>{r.label}</td>
                            <td>
                                <CategoryBadge category={r.category} />
                            </td>
                            <td className="num-col">{num(r.value)}</td>
                        </tr>
                    ))}
            </tbody>
            <tfoot>
                <tr>
                    <td colSpan={2}>Total</td>
                    <td className="num-col">{num(total)}</td>
                </tr>
            </tfoot>
        </table>
    );
}

function TypeSection({ t }: { t: TypeBreakdown }) {
    const isDot = t.label.endsWith("(dot)");
    return (
        <>
            <h2 className="section-head">
                {t.label}
                <span className="muted"> — {num(t.total)} per hit</span>
            </h2>
            <div className="breakdown-columns">
                <div>
                    <div className="breakdown-col-head">Flat damage</div>
                    <ContribTable
                        rows={t.flat}
                        valueLabel="Flat"
                        total={t.flatSubtotal}
                    />
                </div>
                {!isDot && t.percent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">% increase</div>
                        <ContribTable
                            rows={t.percent}
                            valueLabel="%"
                            total={t.totalPercent}
                        />
                    </div>
                )}
                {isDot && t.durationPercent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">Duration %</div>
                        <ContribTable
                            rows={t.durationPercent}
                            valueLabel="%"
                            total={t.totalDurationPercent}
                        />
                    </div>
                )}
                {isDot && t.damagePercent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">Damage %</div>
                        <ContribTable
                            rows={t.damagePercent}
                            valueLabel="%"
                            total={t.totalDamagePercent}
                        />
                    </div>
                )}
            </div>
            {isDot && (
                <p className="muted breakdown-formula">
                    {num(t.flatSubtotal)} x (1 + {num(t.totalDurationPercent)}
                    %) x (1 + {num(t.totalDamagePercent)}%) = {num(t.total)}
                </p>
            )}
        </>
    );
}
```

- [ ] **Step 2: Add layout styles**

Add to `frontend/src/styles.css`, after the Task 3 `.contrib-table` rules:

```css
.breakdown-columns {
    display: flex;
    flex-wrap: wrap;
    gap: 10px 32px;
}
.breakdown-col-head {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--muted);
    margin-bottom: 4px;
}
.breakdown-formula {
    font-size: 12px;
    margin-top: -2px;
}
```

- [ ] **Step 3: Type-check and manually verify**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean.

Run: `cd frontend && npm run dev`, open the breakdown page for an attack that deals more than one damage type (or has a DoT component, e.g. a Fire-DoT skill). Expected: one section per damage type with flat/percent tables whose totals match the "per hit" figure shown in the heading; a DoT-labeled type ("... (dot)") shows Duration %/Damage % columns and the formula line instead of a single % column. Stop the dev server afterward.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/views/AttackBreakdownView.tsx frontend/src/styles.css
git commit -m "$(cat <<'EOF'
Add per-damage-type flat/percent contributor sections

DoT types get their duration% and damage% contributor lists shown
separately (a DoT's total is flat x (1+duration%) x (1+damage%) —
two multiplicative pools, not one combined percent).
EOF
)"
```

---

### Task 5: Retaliation section

**Files:**
- Modify: `frontend/src/views/AttackBreakdownView.tsx`

**Interfaces:**
- Consumes: `RetaliationBreakdown`, `RetaliationTypeBreakdown` (Task 1); `ContribTable`, `CategoryBadge` (Tasks 3-4, same file).

- [ ] **Step 1: Add the retaliation section**

In `frontend/src/views/AttackBreakdownView.tsx`, add `RetaliationBreakdown` and `RetaliationTypeBreakdown` to the `../api` import, and render it conditionally after the per-type sections:

```tsx
            {bd.types.map((t, i) => (
                <TypeSection key={i} t={t} />
            ))}

            {bd.retaliation && <RetaliationSection r={bd.retaliation} />}
```

Add the component:

```tsx
function RetaliationSection({ r }: { r: RetaliationBreakdown }) {
    return (
        <>
            <h2 className="section-head">Retaliation added to attack</h2>
            <div className="breakdown-col-head">% of retaliation damage added to attack</div>
            <ContribTable
                rows={r.addToAttackPct}
                valueLabel="%"
                total={r.totalAddToAttackPct}
            />
            {r.byType.map((t, i) => (
                <RetaliationTypeBlock key={i} t={t} />
            ))}
        </>
    );
}

function RetaliationTypeBlock({ t }: { t: RetaliationTypeBreakdown }) {
    return (
        <div className="retaliation-type-block">
            <h3 className="breakdown-subhead">{t.label}</h3>
            <div className="breakdown-columns">
                <div>
                    <div className="breakdown-col-head">Flat retaliation</div>
                    <ContribTable
                        rows={t.flat}
                        valueLabel="Flat"
                        total={t.flatSubtotal}
                    />
                </div>
                {t.percent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">% modifiers</div>
                        <ContribTable
                            rows={t.percent}
                            valueLabel="%"
                            total={t.totalPercent}
                        />
                    </div>
                )}
            </div>
            <p className="muted breakdown-formula">
                {num(t.flatSubtotal)} x (1 + {num(t.totalPercent)}%) ={" "}
                {num(t.retaliationDamage)} retaliation damage &rarr;{" "}
                {num(t.addedToAttack)} added to this attack
            </p>
        </div>
    );
}
```

- [ ] **Step 2: Add styles**

Add to `frontend/src/styles.css`:

```css
.retaliation-type-block + .retaliation-type-block {
    margin-top: 14px;
}
.breakdown-subhead {
    font-size: 14px;
    margin: 10px 0 4px;
}
```

- [ ] **Step 3: Type-check and manually verify**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean.

Run: `cd frontend && npm run dev`. If you have (or can temporarily give a test character, via the existing gear-override pickers on the character page) a shield/retaliation setup — flat retaliation stat plus something granting "% retaliation damage added to attack" (e.g. the Reprisal transmuter on Cadence) — open that attack's breakdown page and confirm the Retaliation section appears with the expected numbers. If no such build is available in your save data, at minimum confirm a character *without* retaliation shows no Retaliation section at all (the `bd.retaliation` null case). Stop the dev server afterward.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/views/AttackBreakdownView.tsx frontend/src/styles.css
git commit -m "$(cat <<'EOF'
Add the retaliation-added-to-attack section

Shows the shared "% added to attack" contributors once, then each
affected damage type's own flat retaliation stat and % modifiers,
so a shield/retaliation build can see which piece carries the
retaliation damage and which skill converts it into attack damage.
EOF
)"
```

---

### Task 6: Rate factors + proc trigger info

**Files:**
- Modify: `frontend/src/views/AttackBreakdownView.tsx`

**Interfaces:**
- Consumes: `RateFactor`, `Trigger` (Task 1); `ContribTable` (Task 4, same file).

- [ ] **Step 1: Add the rate/trigger section**

In `frontend/src/views/AttackBreakdownView.tsx`, add `RateFactor` and `Trigger` to the `../api` import, and render it last in `AttackBreakdownView`'s JSX:

```tsx
            {bd.retaliation && <RetaliationSection r={bd.retaliation} />}

            {bd.rateFactors.length > 0 && (
                <>
                    <h2 className="section-head">Rate</h2>
                    {bd.rateFactors.map((rf, i) => (
                        <RateFactorBlock key={i} rf={rf} />
                    ))}
                </>
            )}
            {bd.trigger && <TriggerBlock trigger={bd.trigger} />}
```

Add the components:

```tsx
function RateFactorBlock({ rf }: { rf: RateFactor }) {
    return (
        <div className="retaliation-type-block">
            <h3 className="breakdown-subhead">{rf.label}</h3>
            <ContribTable
                rows={rf.contributions}
                valueLabel="%"
                total={rf.contributions.reduce((s, c) => s + c.value, 0)}
            />
            <p className="muted breakdown-formula">{rf.formula}</p>
        </div>
    );
}

function TriggerBlock({ trigger }: { trigger: Trigger }) {
    return (
        <>
            <h2 className="section-head">Trigger</h2>
            <p className="muted">
                {num(trigger.chancePct)}% chance on attack, {num(trigger.cooldown)}s
                cooldown — granted by {trigger.grantedBy}.
            </p>
        </>
    );
}
```

- [ ] **Step 2: Type-check and manually verify**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean.

Run: `cd frontend && npm run dev`. Check three cases: (1) a weapon%-based active attack shows "Attack Speed" and possibly "Weapon Damage %" rate factors; (2) a cooldown-based active attack shows "Cooldown Reduction"; (3) a proc (item/devotion/on-hit) shows the Trigger line with a sensible "granted by" source instead of rate-factor tables. Stop the dev server afterward.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/views/AttackBreakdownView.tsx
git commit -m "$(cat <<'EOF'
Add rate-factor and proc-trigger sections to the breakdown page

Completes the page: attack speed / cooldown reduction / weapon
damage % contributors for active attacks, or chance/cooldown/
granting-source info for procs.
EOF
)"
```

---

### Task 7: Polish pass + full manual verification

**Files:**
- Modify: `frontend/src/styles.css` (any visual rough edges found below)

- [ ] **Step 1: Full walkthrough**

Run: `cd frontend && npm run dev`, open the app, and walk through:

1. From a character with several attack skills, click through *every* active attack card and every proc card, confirming each breakdown page loads without console errors (check the browser dev tools console).
2. Confirm the "Sources ranked by DPS impact" table's top entries make intuitive sense (e.g. the equipped weapon or highest-damage item should usually rank near the top for a weapon-based attack).
3. Confirm every per-type table's flat/percent totals sum to the numbers shown in the section heading and the top-of-page per-hit figure (spot-check the arithmetic on one or two rows).
4. Confirm the "Back to <name>" link returns to the character page with the *same* overrides/difficulty still applied (change a gear override on the character page first, then visit a breakdown page, then click back — the override should still be there, since it's read from `localStorage`, not the URL).
5. Resize the browser window narrow (mobile-ish width) and confirm the tables/columns don't overflow unreadably — adjust `.breakdown-columns`/`.contrib-table` CSS (`flex-wrap`, `max-width`) if they do.

- [ ] **Step 2: Fix any visual issues found**

Make any necessary CSS adjustments directly in `frontend/src/styles.css` based on Step 1's findings. If none are found, skip to Step 3.

- [ ] **Step 3: Final build check**

Run: `cd frontend && npm run build 2>&1 | tail -40`
Expected: clean.

- [ ] **Step 4: Commit (only if Step 2 made changes)**

```bash
git add frontend/src/styles.css
git commit -m "$(cat <<'EOF'
Polish the attack breakdown page layout

EOF
)"
```

## Definition of done

- `npm run build` clean.
- Every attack/proc card on the character page is clickable and leads to a fully populated breakdown page (impact ranking, per-type flat/% tables, retaliation section when applicable, rate/trigger section).
- Manually verified in a running dev server per Task 7.
