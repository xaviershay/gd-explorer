import { Gear } from "../api";
import { rarityColor } from "../colors";
import { groupBonuses, GroupedStats } from "../bonuses";

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
    gear.type,
    gear.classification,
    gear.levelRequirement ? `lvl ${gear.levelRequirement}` : null,
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
