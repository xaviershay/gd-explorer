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

// Per-gear-slot component/augment override; value is a record, or "none" to
// clear. Keyed by the gear's index in CharacterDetail.gear.
export interface SlotOverride {
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

export interface StatSummary {
    difficulty: string;
    resists: ResistStat[];
    attributes: NamedValue[];
    keyTotals: KeyTotal[];
    damage: string[];
}

export interface ShoppingItem {
    record: string;
    name: string;
    kind: "component" | "augment";
    source: string | null;
    count: number;
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

export interface CharacterDetail {
    name: string;
    level: number;
    className: string;
    hardcore: boolean;
    summary: StatSummary;
    attacks: Attack[];
    gear: Gear[];
    shopping: ShoppingItem[];
}

async function getJSON<T>(path: string): Promise<T> {
    const res = await fetch(path);
    if (!res.ok) throw new Error(`${path}: ${res.status} ${res.statusText}`);
    return res.json() as Promise<T>;
}

export const getSets = () => getJSON<SetView[]>("/api/sets");
export const getCharacters = () =>
    getJSON<CharacterSummary[]>("/api/characters");
export const getEnhancements = () => getJSON<Catalog>("/api/enhancements");

export function getCharacter(
    name: string,
    overrides: Overrides = {},
): Promise<CharacterDetail> {
    const qs = new URLSearchParams();
    for (const [i, o] of Object.entries(overrides)) {
        if (o.component !== undefined) qs.set(`comp.${i}`, o.component);
        if (o.augment !== undefined) qs.set(`aug.${i}`, o.augment);
    }
    const q = qs.toString();
    return getJSON<CharacterDetail>(
        `/api/characters/${encodeURIComponent(name)}${q ? `?${q}` : ""}`,
    );
}

// Records-in-best-first-order ranking for the components/augments compatible
// with a given gear slot, holding the rest of the build (with overrides
// applied) constant. Mirrors the scoring used by the `upgrades` CLI.
export function getEnhancementRanking(
    name: string,
    slot: number,
    kind: "component" | "augment",
    overrides: Overrides = {},
): Promise<string[]> {
    const qs = new URLSearchParams();
    qs.set("slot", String(slot));
    qs.set("kind", kind);
    for (const [i, o] of Object.entries(overrides)) {
        if (o.component !== undefined) qs.set(`comp.${i}`, o.component);
        if (o.augment !== undefined) qs.set(`aug.${i}`, o.augment);
    }
    return getJSON<string[]>(
        `/api/characters/${encodeURIComponent(name)}/rank?${qs.toString()}`,
    );
}
