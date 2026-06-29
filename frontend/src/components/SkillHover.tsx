import { useRef, useState } from "react";
import { createPortal } from "react-dom";
import { SkillInfo } from "../api";
import { skillNameOf } from "../skills";
import { elementColor } from "../elements";

// A skill bonus line ("Grants X", "+N to X") that reveals a hover card with the
// skill's description and what it grants. Lines with no known skill render as
// plain text. The card is portalled to <body> with fixed positioning so it's
// never clipped by scroll/overflow containers (e.g. picker dropdowns).
export function SkillHover({
  line,
  info,
}: {
  line: string;
  info?: SkillInfo;
}) {
  const ref = useRef<HTMLSpanElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  if (!info) return <>{line}</>;

  const show = () => {
    const r = ref.current?.getBoundingClientRect();
    if (r) setPos({ left: r.left, top: r.bottom + 4 });
  };
  const hide = () => setPos(null);

  const name = skillNameOf(line);
  const resistDmg = [...info.bonuses.resistBonuses, ...info.bonuses.damageBonuses];
  const other = [...info.bonuses.bonuses, ...info.bonuses.skillBonuses];

  return (
    <span
      ref={ref}
      className="skill-line"
      onMouseEnter={show}
      onMouseLeave={hide}
    >
      {line}
      {pos &&
        createPortal(
          <div
            className="skill-card"
            style={{ left: pos.left, top: pos.top }}
          >
            {name && <div className="skill-card-name">{name}</div>}
            {info.description && (
              <div className="skill-card-desc">{info.description}</div>
            )}
            {(resistDmg.length > 0 || other.length > 0) && (
              <ul className="skill-card-grants">
                {resistDmg.map((g, i) => (
                  <li key={"r" + i} style={{ color: elementColor(g) }}>
                    {g}
                  </li>
                ))}
                {other.map((g, i) => (
                  <li key={"o" + i}>{g}</li>
                ))}
              </ul>
            )}
          </div>,
          document.body,
        )}
    </span>
  );
}
