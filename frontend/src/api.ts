// Types mirror the JSON emitted by GrimDawn.Web.View (camelCase fields).

export interface Holding {
    location: string;
    count: number;
}

// Stat bonuses split by category (mirrors a Gear's bonus arrays).
export interface BonusGroups {
    resistBonuses: string[];
    damageBonuses: string[];
    bonuses: string[];
    skillBonuses: string[];
}

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

export interface SetView {
    name: string;
    record: string;
    ownedCount: number;
    total: number;
    complete: boolean;
    level: number | null;
    members: SetMember[];
}

export interface CharacterSummary {
    name: string;
    level: number;
    className: string;
    hardcore: boolean;
    equippedCount: number;
    equippedSetPieces: number;
}

export interface Enhancement {
    record: string;
    name: string;
    classification: string | null;
    level: number | null;
    slots: string[];
    resistBonuses: string[];
    damageBonuses: string[];
    bonuses: string[];
    skillBonuses: string[];
}

export interface Catalog {
    components: Enhancement[];
    augments: Enhancement[];
}

// Per-gear-slot override; each value is a record, or "none" to clear/revert.
// `item` swaps the base item (keeping its component/augment). Keyed by the
// gear's index in CharacterDetail.gear.
export interface SlotOverride {
    item?: string;
    component?: string;
    augment?: string;
}
export type Overrides = Record<number, SlotOverride>;

export interface Gear {
    name: string;
    record: string;
    component: string | null;
    augment: string | null;
    type: string | null;
    classification: string | null;
    levelRequirement: number | null;
    resistBonuses: string[];
    damageBonuses: string[];
    bonuses: string[];
    skillBonuses: string[];
    isSet: boolean;
    setRecord: string | null;
}

export interface ResistStat {
    name: string;
    value: number;
    cap: number;
    overcap: number;
}

export interface NamedValue {
    label: string;
    value: number;
}

export interface KeyTotal {
    label: string;
    flat: number;
    pct: number;
}

export interface DamageRow {
    type: string;
    instFlatLo: number;
    instFlatHi: number;
    instPct: number;
    dotFlatLo: number;
    dotFlatHi: number;
    dotPct: number;
}

export interface StatSummary {
    difficulty: string;
    resists: ResistStat[];
    attributes: NamedValue[];
    keyTotals: KeyTotal[];
    health: number;
    energy: number;
    oa: number;
    da: number;
    damage: string[];
    damageTable: DamageRow[];
    ccResists: ResistStat[];
}

export interface ShoppingItem {
    record: string;
    name: string;
    kind: "item" | "component" | "augment";
    source: string | null; // augment: faction vendor; item: owned location
    standing: string | null; // augments only: minimum faction standing required
    count: number;
    slots: string[];
}

export interface Attack {
    name: string;
    rank: number | null;
    kind: "active" | "proc";
    perHit: number;
    dps: number;
    rate: string;
    types: NamedValue[];
}

export interface SkillEntry {
    name: string;
    rank: number;
}

export interface MasteryGroup {
    name: string;
    rank: number;
    skills: SkillEntry[];
}

export interface ConstellationEntry {
    name: string;
    stars: number;
    power: string | null;
    bonuses: BonusGroups;
}

export interface CharacterDetail {
    name: string;
    level: number;
    className: string;
    hardcore: boolean;
    summary: StatSummary;
    attacks: Attack[];
    gear: Gear[];
    armorTable: NamedValue[];
    shopping: ShoppingItem[];
    masteries: MasteryGroup[];
    devotions: ConstellationEntry[];
}

async function getJSON<T>(path: string): Promise<T> {
    const res = await fetch(path);
    if (!res.ok) throw new Error(`${path}: ${res.status} ${res.statusText}`);
    return res.json() as Promise<T>;
}

// A craftable component or relic and its blueprint status:
//  - "learned": a Blueprint recipe you've found.
//  - "missing": a Blueprint recipe not found yet.
//  - "default": always craftable at the blacksmith (no blueprint needed).
export interface Craftable {
    name: string;
    record: string;
    classification: string | null;
    level: number | null;
    status: "learned" | "default" | "missing";
    bonuses: BonusGroups;
}

export const getComponents = () => getJSON<Craftable[]>("/api/components");
export const getRelics = () => getJSON<Craftable[]>("/api/relics");

// A skill's hover-card payload: its description and what it grants.
export interface SkillInfo {
    description: string;
    bonuses: BonusGroups;
}

export const getSets = () => getJSON<SetView[]>("/api/sets");
export const getCharacters = () =>
    getJSON<CharacterSummary[]>("/api/characters");
export const getEnhancements = () => getJSON<Catalog>("/api/enhancements");

export type Difficulty = "normal" | "elite" | "ultimate";

// Add the per-slot override + difficulty params shared by every character query.
function applyParams(
    qs: URLSearchParams,
    overrides: Overrides,
    difficulty: Difficulty,
) {
    for (const [i, o] of Object.entries(overrides)) {
        if (o.item !== undefined) qs.set(`item.${i}`, o.item);
        if (o.component !== undefined) qs.set(`comp.${i}`, o.component);
        if (o.augment !== undefined) qs.set(`aug.${i}`, o.augment);
    }
    if (difficulty !== "ultimate") qs.set("difficulty", difficulty);
}

export function getCharacter(
    name: string,
    overrides: Overrides = {},
    difficulty: Difficulty = "ultimate",
): Promise<CharacterDetail> {
    const qs = new URLSearchParams();
    applyParams(qs, overrides, difficulty);
    const q = qs.toString();
    return getJSON<CharacterDetail>(
        `/api/characters/${encodeURIComponent(name)}${q ? `?${q}` : ""}`,
    );
}

// Records-in-best-first-order ranking for the components/augments compatible
// with a given gear slot, holding the rest of the build (with overrides
// applied) constant. Mirrors the scoring used by the `upgrades` CLI; the score
// deltas are returned so the UI can both rank and explain.
export interface RankEntry {
    record: string;
    score: number;
    oaDelta: number;
    daDelta: number;
    dpsDelta: number;
}

export function getEnhancementRanking(
    name: string,
    slot: number,
    kind: "component" | "augment",
    overrides: Overrides = {},
    difficulty: Difficulty = "ultimate",
): Promise<RankEntry[]> {
    const qs = new URLSearchParams();
    qs.set("slot", String(slot));
    qs.set("kind", kind);
    applyParams(qs, overrides, difficulty);
    return getJSON<RankEntry[]>(
        `/api/characters/${encodeURIComponent(name)}/rank?${qs.toString()}`,
    );
}

// An owned item that could go in a gear slot, scored by the `upgrades` path
// (it inherits the slot's component/augment). `location` says which
// character/stash holds it.
export interface ItemRank {
    record: string;
    name: string;
    location: string;
    level: number | null;
    classification: string | null;
    score: number;
    oaDelta: number;
    daDelta: number;
    dpsDelta: number;
    resistDeltas: string[];
}

export function getItemRanking(
    name: string,
    slot: number,
    overrides: Overrides = {},
    difficulty: Difficulty = "ultimate",
): Promise<ItemRank[]> {
    const qs = new URLSearchParams();
    qs.set("slot", String(slot));
    applyParams(qs, overrides, difficulty);
    return getJSON<ItemRank[]>(
        `/api/characters/${encodeURIComponent(name)}/items?${qs.toString()}`,
    );
}

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
