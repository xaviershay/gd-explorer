import { useState } from "react";
import { getSets, BonusGroups, SetView, SetMember } from "../api";
import { useAsync } from "../hooks";
import { rarityColor } from "../colors";
import { BonusItem, orderedResists } from "../elements";
import { BonusSource, groupBonuses, GroupedStats } from "../bonuses";
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
          not owned. Colour = rarity; a coloured outline means you don't own it but
          have the blueprint to craft it. Click a set to see its pieces and combined
          totals.
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

// The preview panel for the selected set: the combined totals of wearing the
// whole set, then each piece in game-style detail.
function SetPreview({ set }: { set: SetView }) {
  // Each piece's own stats plus the set bonuses it unlocks. Set bonuses are
  // per-tier deltas, so summing every piece counts the full set bonus exactly
  // once (no double counting).
  const sources: BonusSource[] = set.members.map((m) => ({
    resistBonuses: [...m.gear.resistBonuses, ...m.setBonus.resistBonuses],
    damageBonuses: [...m.gear.damageBonuses, ...m.setBonus.damageBonuses],
    bonuses: [...m.gear.bonuses, ...m.setBonus.bonuses],
    skillBonuses: [...m.gear.skillBonuses, ...m.setBonus.skillBonuses],
  }));
  const { resists, groups } = groupBonuses(sources);
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

      <div className="set-totals">
        <div className="set-totals-head">Combined set totals</div>
        <GroupedStats resists={orderedResists(resists)} groups={groups} />
      </div>

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

// Flatten a set-bonus group into one ordered list for the per-piece display.
function flattenBonus(b: BonusGroups): string[] {
  return [...b.resistBonuses, ...b.damageBonuses, ...b.bonuses, ...b.skillBonuses];
}
