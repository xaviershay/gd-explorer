import { BonusItem, orderedResists, ResistEntry, ResistRow } from "./elements";

// Stat bonuses grouped for display, matching the set view's "Combined totals":
// resistances summarised as icons, everything else bucketed into these groups.
export type Group = "skills" | "stats" | "combat" | "other";
export const GROUP_ORDER: Group[] = ["skills", "stats", "combat", "other"];
export const GROUP_LABEL: Record<Group, string> = {
  skills: "Skills",
  stats: "Stats",
  combat: "Combat",
  other: "Other",
};

// One contributor of bonus lines (a gear item, or a set member's gear+setBonus).
export interface BonusSource {
  resistBonuses: string[];
  damageBonuses: string[];
  bonuses: string[];
  skillBonuses: string[];
}

// A line parsed into a number (or numeric range) + a label.
interface Stat {
  lo: number;
  hi: number;
  percent: boolean;
  label: string;
  range: boolean;
  inc: boolean; // "Increases <label> by N%" form
}

// "<N>% <Type>" — resistance lines (same shape as % damage, so they're read only
// from the resistBonuses arrays, never merged with damage by label).
const RESIST_RE = /^\+?\s*(-?\d+(?:\.\d+)?)\s*%?\s+(.*\S)\s*$/;
// "+12-22 Cold", "+16% Health", "+3 to all Skills".
const NUM_RE = /^\+?\s*(-?\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?\s*(%)?\s+(.*\S)\s*$/;
// "Increases Armor by 8%", "Increases Energy Regeneration by 76%".
const INC_RE = /^Increases\s+(.*\S)\s+by\s+(\d+(?:\.\d+)?)%$/i;

// Group bonus lines across one or more sources: resistances summed per type, and
// every other stat classified and summed. Summing duplicate labels is a no-op
// for a single item but produces the set totals when given many members.
export function groupBonuses(sources: BonusSource[]): {
  resists: ResistEntry[];
  groups: Record<Group, string[]>;
} {
  const rsum = new Map<string, number>();
  const byGroup: Record<Group, string[]> = { skills: [], stats: [], combat: [], other: [] };

  for (const s of sources) {
    for (const line of s.resistBonuses) {
      const r = RESIST_RE.exec(line.trim());
      if (r) rsum.set(r[2], (rsum.get(r[2]) ?? 0) + parseFloat(r[1]));
    }
    // Damage is combat; skills are skills; character bonuses are classified.
    byGroup.combat.push(...s.damageBonuses);
    byGroup.skills.push(...s.skillBonuses);
    for (const line of s.bonuses) byGroup[classifyBonus(line)].push(line);
  }

  const resists = [...rsum.entries()].map(([label, value]) => ({ label, value }));
  const groups = { skills: [], stats: [], combat: [], other: [] } as Record<Group, string[]>;
  for (const g of GROUP_ORDER) groups[g] = aggregate(byGroup[g]);
  return { resists, groups };
}

// Classify a character bonus (the "bonuses" array) into a display group.
function classifyBonus(line: string): Group {
  const t = line.toLowerCase();
  if (/^grants /.test(t)) return "skills";
  if (/offensive ability|defensive ability|retaliation|armor piercing|\bcrit/.test(t)) return "combat";
  if (/health|energy|physique|cunning|spirit|armor|regenerat|absorption|constitution/.test(t))
    return "stats";
  return "other";
}

// Sum numeric bonus lines by stat; pass through anything unparseable (deduped).
function aggregate(lines: string[]): string[] {
  const stats = new Map<string, Stat>();
  const other = new Map<string, number>();
  for (const raw of lines) {
    const line = raw.trim();
    const inc = INC_RE.exec(line);
    if (inc) {
      const label = inc[1];
      const v = parseFloat(inc[2]);
      bump(stats, "inc:" + label, () => ({ lo: v, hi: v, percent: true, label, range: false, inc: true }))(
        (s) => {
          s.lo += v;
          s.hi += v;
        },
      );
      continue;
    }
    const m = NUM_RE.exec(line);
    if (!m) {
      other.set(line, (other.get(line) ?? 0) + 1);
      continue;
    }
    const lo = parseFloat(m[1]);
    const hi = m[2] !== undefined ? parseFloat(m[2]) : lo;
    const percent = m[3] === "%";
    const label = m[4];
    bump(stats, (percent ? "%" : "") + label, () => ({
      lo,
      hi,
      percent,
      label,
      range: m[2] !== undefined,
      inc: false,
    }))((s) => {
      s.lo += lo;
      s.hi += hi;
      s.range = s.range || m[2] !== undefined;
    });
  }

  const out = [...stats.values()].sort((a, b) => a.label.localeCompare(b.label)).map(fmtStat);
  for (const [line, n] of other) out.push(n > 1 ? `${line} ×${n}` : line);
  return out;
}

// Insert-or-update helper: returns a function that applies `update` to an
// existing entry, or seeds a new one from `create`.
function bump<T>(map: Map<string, T>, key: string, create: () => T) {
  return (update: (cur: T) => void) => {
    const cur = map.get(key);
    if (cur) update(cur);
    else map.set(key, create());
  };
}

const fmtNum = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(1));

function fmtStat(s: Stat): string {
  const val = s.range && s.lo !== s.hi ? `${fmtNum(s.lo)}-${fmtNum(s.hi)}` : fmtNum(s.lo);
  if (s.inc) return `Increases ${s.label} by ${val}%`;
  return `+${val}${s.percent ? "%" : ""} ${s.label}`;
}

// Render grouped bonuses: a resistance icon row then the non-empty groups.
// `inlineResists` lays the resist chips out inline (for compact item cards)
// rather than the fixed grid used by the set summary.
export function GroupedStats({
  resists,
  groups,
  inlineResists = false,
}: {
  resists: ResistEntry[];
  groups: Record<Group, string[]>;
  inlineResists?: boolean;
}) {
  return (
    <>
      {resists.length > 0 && <ResistRow entries={resists} inline={inlineResists} />}
      {GROUP_ORDER.filter((g) => groups[g].length > 0).map((g) => (
        <div className="total-group" key={g}>
          <div className="total-group-head">{GROUP_LABEL[g]}</div>
          <ul className="ia-lines">
            {groups[g].map((t, i) => (
              <BonusItem key={i} line={t} />
            ))}
          </ul>
        </div>
      ))}
    </>
  );
}

export { orderedResists };
