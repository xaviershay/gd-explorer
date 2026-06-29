import { Gear } from "../api";
import { rarityColor } from "../colors";
import { groupBonuses, GroupedStats } from "../bonuses";

// Render an equipment slot type for display: capitalised, with a trailing
// weapon-hand marker split out, e.g. "head" -> "Head", "ranged2h" -> "Ranged 2H".
function titleizeSlot(t: string): string {
  const cap = (s: string) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
  const m = /^(.*?)([12]h)$/.exec(t);
  return m ? `${cap(m[1])} ${m[2].toUpperCase()}` : cap(t);
}

// In-game-style item attribute block: rarity-coloured name, a type/level meta
// line, then stats grouped (resistance icons + Skills/Stats/Combat/Other) the
// same way as the set view. Reused by the set preview and the character sheet.
export function ItemAttributes({
  gear,
  name,
  resistTable = false,
}: {
  gear: Gear;
  name?: string;
  resistTable?: boolean;
}) {
  const { resists, groups } = groupBonuses([gear]);
  const meta = [
    gear.type ? titleizeSlot(gear.type) : null,
    gear.classification,
    gear.levelRequirement ? `Lvl ${gear.levelRequirement}` : null,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <div className="item-attrs">
      <div className="ia-name" style={{ color: rarityColor(gear.classification) }}>
        {name ?? gear.name}
      </div>
      {meta && <div className="ia-meta muted">{meta}</div>}
      <GroupedStats resists={resists} groups={groups} inlineResists resistTable={resistTable} />
    </div>
  );
}
