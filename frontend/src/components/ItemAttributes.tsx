import { Gear } from "../api";
import { rarityColor } from "../colors";
import { BonusItem } from "../elements";

// In-game-style item attribute block: rarity-coloured name, a type/level meta
// line, then all stat bonuses. Reused by the character detail and pinned bar.
export function ItemAttributes({ gear, name }: { gear: Gear; name?: string }) {
  const lines = [
    ...gear.resistBonuses,
    ...gear.damageBonuses,
    ...gear.bonuses,
    ...gear.skillBonuses,
  ];
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
      {lines.length > 0 && (
        <ul className="ia-lines">
          {lines.map((l, i) => (
            <BonusItem key={i} line={l} />
          ))}
        </ul>
      )}
    </div>
  );
}
