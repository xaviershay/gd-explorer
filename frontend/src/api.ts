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

export interface Gear {
  name: string;
  record: string;
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
}

async function getJSON<T>(path: string): Promise<T> {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`${path}: ${res.status} ${res.statusText}`);
  return res.json() as Promise<T>;
}

export const getSets = () => getJSON<SetView[]>("/api/sets");
export const getCharacters = () => getJSON<CharacterSummary[]>("/api/characters");
export const getCharacter = (name: string) =>
  getJSON<CharacterDetail>(`/api/characters/${encodeURIComponent(name)}`);
