import { useState } from "react";
import { getSets, BonusGroups, SetView, SetMember } from "../api";
import { useAsync } from "../hooks";
import { rarityColor } from "../colors";
import { BonusItem, orderedResists, ResistEntry, ResistRow } from "../elements";
import { ItemAttributes } from "../components/ItemAttributes";
import { ItemImage } from "../components/ItemImage";

// Min-level bands used to group sets.
const BANDS: { label: string; min: number; max: number }[] = [
  { label: "Level 1–24", min: 1, max: 24 },
  { label: "Level 25–49", min: 25, max: 49 },
  { label: "Level 50–69", min: 50, max: 69 },
  { label: "Level 70–83", min: 70, max: 83 },
  { label: "Level 84–93", min: 84, max: 93 },
  { label: "Level 94+", min: 94, max: Infinity },
];

function bandLabel(level: number | null): string {
  if (level == null) return "Unknown level";
  return BANDS.find((b) => level >= b.min && level <= b.max)?.label ?? "Unknown level";
}

export function SetsView() {
  const state = useAsync(getSets, "sets");
  const [selected, setSelected] = useState<string | null>(null);

  if (state.status === "loading") return <p className="muted">Loading sets…</p>;
  if (state.status === "error") return <p className="error">{state.error}</p>;

  // Default to the first set so the preview is populated on first load.
  const selectedRecord = selected ?? state.data[0]?.record ?? null;
  const selectedSet = state.data.find((s) => s.record === selectedRecord) ?? null;

  // group by level band, preserving band order; "Unknown" last.
  const order = [...BANDS.map((b) => b.label), "Unknown level"];
  const groups = new Map<string, SetView[]>();
  for (const s of state.data) {
    const key = bandLabel(s.level);
    const arr = groups.get(key);
    if (arr) arr.push(s);
    else groups.set(key, [s]);
  }

  return (
    <div className="sets-layout">
      <div className="sets-main">
        <h1>Set items ({state.data.length} sets)</h1>
        <p className="muted">
          Each square is a set piece; the number is how many copies you own. Greyed =
          not owned. Colour = rarity. Click a set to see its pieces and combined totals.
        </p>
        {order
          .filter((label) => groups.has(label))
          .map((label) => {
            const sets = groups
              .get(label)!
              .sort(
                (a, b) =>
                  b.ownedCount / b.total - a.ownedCount / a.total ||
                  a.name.localeCompare(b.name),
              );
            return (
              <section key={label}>
                <h2 className="band">{label}</h2>
                <div className="sets-flow">
                  {sets.map((s) => (
                    <SetCard
                      key={s.record}
                      set={s}
                      selected={s.record === selectedRecord}
                      onSelect={() => setSelected(s.record)}
                    />
                  ))}
                </div>
              </section>
            );
          })}
      </div>
      <aside className="set-preview">
        {selectedSet ? (
          <SetPreview set={selectedSet} />
        ) : (
          <p className="muted">Select a set to preview its pieces.</p>
        )}
      </aside>
    </div>
  );
}

function SetCard({
  set,
  selected,
  onSelect,
}: {
  set: SetView;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <div
      className={"set-card" + (selected ? " selected" : "")}
      onClick={onSelect}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && onSelect()}
    >
      <div className="set-card-head">
        <span className={"set-card-name" + (set.complete ? " complete" : "")}>
          {set.name}
        </span>
        <span className="muted">
          {set.ownedCount}/{set.total}
        </span>
      </div>
      <div className="squares">
        {set.members.map((m) => (
          <ItemSquare key={m.record} member={m} />
        ))}
      </div>
    </div>
  );
}

function ItemSquare({ member: m }: { member: SetMember }) {
  const owned = m.count > 0;
  const tooltip =
    `${m.name}` +
    (m.gear.levelRequirement ? ` (lvl ${m.gear.levelRequirement})` : "") +
    `\n${
      owned
        ? `${m.count} owned: ` +
          m.holdings
            .map((h) => `${h.location}${h.count > 1 ? ` ×${h.count}` : ""}`)
            .join(", ")
        : "not owned"
    }`;
  return (
    <div
      className={"item-square" + (owned ? "" : " missing")}
      style={owned ? { background: rarityColor(m.gear.classification) } : undefined}
      title={tooltip}
    >
      {owned ? m.count : ""}
    </div>
  );
}

// The preview panel for the selected set: the combined totals of wearing the
// whole set, then each piece in game-style detail.
function SetPreview({ set }: { set: SetView }) {
  const { resists, groups } = setTotals(set);
  const hasTotals = resists.length > 0 || GROUP_ORDER.some((g) => groups[g].length > 0);
  return (
    <div className="preview">
      <div className="preview-head">
        <span className={"preview-name" + (set.complete ? " complete" : "")}>
          {set.name}
        </span>
        <span className="muted">
          {set.ownedCount}/{set.total} owned
        </span>
      </div>

      {hasTotals && (
        <div className="set-totals">
          <div className="set-totals-head">Combined set totals</div>
          {resists.length > 0 && <ResistRow entries={resists} />}
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
        </div>
      )}

      <div className="preview-items">
        {set.members.map((m) => {
          const bonus = flattenBonus(m.setBonus);
          return (
            <div className={"preview-item" + (m.count > 0 ? "" : " missing")} key={m.record}>
              <ItemImage record={m.record} />
              <div className="pin-body">
                <ItemAttributes gear={m.gear} name={m.name} />
                {bonus.length > 0 && (
                  <div className="set-bonus">
                    <div className="set-bonus-head">
                      Set bonus ({m.setTier} {m.setTier === 1 ? "piece" : "pieces"})
                    </div>
                    <ul className="ia-lines">
                      {bonus.map((b, i) => (
                        <BonusItem key={i} line={b} />
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// --- Compound totals -------------------------------------------------------

// A line parsed into a number (or numeric range) + a label.
interface Stat {
  lo: number;
  hi: number;
  percent: boolean;
  label: string;
  range: boolean;
  inc: boolean; // "Increases <label> by N%" form
}

type Group = "skills" | "stats" | "combat" | "other";
const GROUP_ORDER: Group[] = ["skills", "stats", "combat", "other"];
const GROUP_LABEL: Record<Group, string> = {
  skills: "Skills",
  stats: "Stats",
  combat: "Combat",
  other: "Other",
};

// "<N>% <Type>" — resistance lines (same shape as % damage, so they must be
// read only from the resistBonuses arrays, never merged with damage by label).
const RESIST_RE = /^\+?\s*(-?\d+(?:\.\d+)?)\s*%?\s+(.*\S)\s*$/;
// "+12-22 Cold", "+16% Health", "+3 to all Skills".
const NUM_RE = /^\+?\s*(-?\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?\s*(%)?\s+(.*\S)\s*$/;
// "Increases Armor by 8%", "Increases Energy Regeneration by 76%".
const INC_RE = /^Increases\s+(.*\S)\s+by\s+(\d+(?:\.\d+)?)%$/i;

// The effect of wearing the whole set: each piece's own stats plus the set
// bonuses it unlocks. Set bonuses are per-tier deltas, so summing every piece's
// counts the full set bonus exactly once (no double counting). Resistances are
// summed per type for the icon row; everything else is grouped and summed.
function setTotals(set: SetView): {
  resists: ResistEntry[];
  groups: Record<Group, string[]>;
} {
  const rsum = new Map<string, number>();
  const byGroup: Record<Group, string[]> = { skills: [], stats: [], combat: [], other: [] };

  const addResists = (lines: string[]) => {
    for (const line of lines) {
      const r = RESIST_RE.exec(line.trim());
      if (!r) continue;
      rsum.set(r[2], (rsum.get(r[2]) ?? 0) + parseFloat(r[1]));
    }
  };

  for (const m of set.members) {
    addResists(m.gear.resistBonuses);
    addResists(m.setBonus.resistBonuses);
    // Damage is combat; skills are skills; character bonuses are classified.
    byGroup.combat.push(...m.gear.damageBonuses, ...m.setBonus.damageBonuses);
    byGroup.skills.push(...m.gear.skillBonuses, ...m.setBonus.skillBonuses);
    for (const line of [...m.gear.bonuses, ...m.setBonus.bonuses]) {
      byGroup[classifyBonus(line)].push(line);
    }
  }

  // Always show every canonical resistance slot (0% when absent).
  const resists = orderedResists([...rsum.entries()].map(([label, value]) => ({ label, value })));
  const groups = { skills: [], stats: [], combat: [], other: [] } as Record<Group, string[]>;
  for (const g of GROUP_ORDER) groups[g] = aggregate(byGroup[g]);
  return { resists, groups };
}

// Classify a character bonus (the "bonuses" array) into a display group.
function classifyBonus(line: string): Group {
  const t = line.toLowerCase();
  if (/^grants /.test(t)) return "skills";
  if (/offensive ability|defensive ability|retaliation|armor piercing|\bcrit/.test(t))
    return "combat";
  if (/health|energy|physique|cunning|spirit|armor|regenerat|absorption|constitution/.test(t))
    return "stats";
  return "other";
}

// Flatten a set-bonus group into one ordered list for the per-piece display.
function flattenBonus(b: BonusGroups): string[] {
  return [...b.resistBonuses, ...b.damageBonuses, ...b.bonuses, ...b.skillBonuses];
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
      bump(stats, "inc:" + label, () => ({
        lo: v,
        hi: v,
        percent: true,
        label,
        range: false,
        inc: true,
      }))((s) => {
        s.lo += v;
        s.hi += v;
      });
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

  const out = [...stats.values()]
    .sort((a, b) => a.label.localeCompare(b.label))
    .map(fmtStat);
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
