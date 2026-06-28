import type { ReactNode } from "react";

// Grim Dawn damage/resistance "elements". DoT variants (Burn, Frostburn,
// Electrocute, Poison, Vitality Decay, Internal Trauma) fold into their base
// element so they share its colour and icon.
export type Element =
  | "fire"
  | "cold"
  | "lightning"
  | "acid"
  | "vitality"
  | "aether"
  | "chaos"
  | "bleeding"
  | "physical"
  | "pierce"
  | "elemental";

export const ELEMENT_COLOR: Record<Element, string> = {
  fire: "#ff7a3c",
  cold: "#5db8ff",
  lightning: "#ffce3a",
  acid: "#9fd13a",
  vitality: "#c062d8",
  aether: "#74e0d6",
  chaos: "#e0533a",
  bleeding: "#e84a5f",
  physical: "#dcd6c2",
  pierce: "#d4b76a",
  elemental: "#f4a93a",
};

// The resistance slots shown in the summary, always rendered in this order
// (like the in-game panel) so each type keeps a consistent position even at 0%.
export const RESISTANCES: { label: string; element: Element }[] = [
  { label: "Fire", element: "fire" },
  { label: "Cold", element: "cold" },
  { label: "Lightning", element: "lightning" },
  { label: "Poison & Acid", element: "acid" },
  { label: "Pierce", element: "pierce" },
  { label: "Bleeding", element: "bleeding" },
  { label: "Vitality", element: "vitality" },
  { label: "Aether", element: "aether" },
  { label: "Chaos", element: "chaos" },
  { label: "Physical", element: "physical" },
];

// Display order roughly matching the in-game resistance panel.
const ORDER: Element[] = [
  "fire",
  "cold",
  "lightning",
  "acid",
  "aether",
  "vitality",
  "chaos",
  "bleeding",
  "pierce",
  "physical",
  "elemental",
];
export const elementRank = (e: Element | null): number =>
  e ? ORDER.indexOf(e) : ORDER.length;

// Classify a bonus line/label by its element, most-specific keyword first so the
// DoT variants beat their base type. Returns null for non-elemental stats.
export function elementOf(text: string): Element | null {
  const t = text.toLowerCase();
  if (t.includes("vitality")) return "vitality"; // incl. "Vitality Decay"
  if (t.includes("internal trauma")) return "physical";
  if (t.includes("bleed")) return "bleeding";
  if (t.includes("frostburn")) return "cold";
  if (t.includes("electrocute")) return "lightning";
  if (t.includes("burn")) return "fire";
  if (t.includes("poison") || t.includes("acid")) return "acid";
  if (t.includes("chaos")) return "chaos";
  if (t.includes("aether")) return "aether";
  if (t.includes("cold")) return "cold";
  if (t.includes("fire")) return "fire";
  if (t.includes("lightning")) return "lightning";
  if (t.includes("pierce")) return "pierce";
  if (t.includes("elemental")) return "elemental";
  if (t.includes("physical")) return "physical";
  return null;
}

export const elementColor = (text: string): string | undefined => {
  const e = elementOf(text);
  return e ? ELEMENT_COLOR[e] : undefined;
};

// Simple inline glyphs (16x16) evoking the in-game element icons. Colour comes
// from the parent via `fill`/`currentColor`.
const ICON_PATHS: Record<Element, ReactNode> = {
  fire: (
    <path d="M8 1c1.6 2.6 4 3.7 3 6.6.9-.4 1.5-1.3 1.6-2.4 1.6 2 2 5.1-1.1 7.2-1.4 1-3.6 1-5 0-2.6-1.8-2.6-4.8-.4-6.4.2 1 .8 1.7 1.6 2C7.4 5 6.7 3 8 1z" />
  ),
  cold: (
    <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinecap="round">
      <path d="M8 1v14M2 4.5l12 7M14 4.5l-12 7" />
      <path d="M8 4l-2-1.5M8 4l2-1.5M8 12l-2 1.5M8 12l2 1.5" />
    </g>
  ),
  lightning: <path d="M9.5 1L3 9.2h3.6L5 15l7-8.4H8.3L9.5 1z" />,
  acid: <path d="M8 1.6c3 4 4.6 6.1 4.6 8.1a4.6 4.6 0 11-9.2 0c0-2 1.6-4.1 4.6-8.1z" />,
  vitality: (
    <path
      fillRule="evenodd"
      d="M8 1.4A5.6 5.6 0 002.4 7c0 2 1 3.6 2.5 4.5v2A.5.5 0 005.4 14H6v-1.3h1.2V14h1.6v-1.3H10V14h.6a.5.5 0 00.5-.5v-2C12.6 10.6 13.6 9 13.6 7A5.6 5.6 0 008 1.4zM5.9 6.1a1.4 1.4 0 100 2.8 1.4 1.4 0 000-2.8zm4.2 0a1.4 1.4 0 100 2.8 1.4 1.4 0 000-2.8z"
    />
  ),
  aether: <path d="M8 1l1.7 5.3L15 8l-5.3 1.7L8 15l-1.7-5.3L1 8l5.3-1.7z" />,
  chaos: (
    <path d="M8 1l1.4 3.3 3.3-1.4-1.4 3.3L14.6 8l-3.3 1.4 1.4 3.3-3.3-1.4L8 14.6l-1.4-3.3-3.3 1.4 1.4-3.3L1.4 8l3.3-1.4-1.4-3.3 3.3 1.4z" />
  ),
  bleeding: <path d="M8 1.6c3 4 4.6 6.1 4.6 8.1a4.6 4.6 0 11-9.2 0c0-2 1.6-4.1 4.6-8.1z" />,
  physical: <path d="M8 1l5.2 2v4.1c0 3.6-2.3 6.7-5.2 8.2-2.9-1.5-5.2-4.6-5.2-8.2V3z" />,
  pierce: <path d="M8 1l4.2 5.2H9.3V15H6.7V6.2H3.8z" />,
  elemental: (
    <g>
      <circle cx="5.5" cy="6" r="3" fill={ELEMENT_COLOR.fire} />
      <circle cx="10.5" cy="6" r="3" fill={ELEMENT_COLOR.cold} />
      <circle cx="8" cy="10.5" r="3" fill={ELEMENT_COLOR.lightning} />
    </g>
  ),
};

export function ElementIcon({
  element,
  size = 18,
}: {
  element: Element;
  size?: number;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill={element === "elemental" ? "none" : "currentColor"}
      aria-hidden="true"
    >
      {ICON_PATHS[element]}
    </svg>
  );
}

// A single stat line, tinted by its element (plain text when non-elemental).
export function BonusItem({ line }: { line: string }) {
  return <li style={{ color: elementColor(line) }}>{line}</li>;
}

const ELEMENT_BY_LABEL = new Map(RESISTANCES.map((r) => [r.label, r.element]));
const fmtPct = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(1));

export interface ResistEntry {
  label: string;
  value: number;
  cap?: number;
  overcap?: number;
}

// Build a full, fixed-order list of resistance entries (one per canonical slot,
// 0 when absent), looking values up by label from the supplied entries.
export function orderedResists(entries: ResistEntry[]): ResistEntry[] {
  const byLabel = new Map(entries.map((e) => [e.label, e]));
  const known = new Set(RESISTANCES.map((r) => r.label));
  return [
    ...RESISTANCES.map((r) => byLabel.get(r.label) ?? { label: r.label, value: 0 }),
    ...entries.filter((e) => !known.has(e.label)),
  ];
}

// A fixed 2-column × 5-row resistance table: every canonical resistance in a
// consistent position (icon label + value), with absent ones greyed. Used by the
// character summary and each equipped item so positions line up across the page.
export function ResistTable({ entries }: { entries: ResistEntry[] }) {
  const all = orderedResists(entries);
  return (
    <div className="resist-table">
      {all.map((r) => {
        const el = ELEMENT_BY_LABEL.get(r.label) ?? elementOf(r.label);
        const capNote =
          r.cap !== undefined
            ? ` — ${fmtPct(r.value)}% (cap ${fmtPct(r.cap)}${
                r.overcap ? `, +${fmtPct(r.overcap)} over` : ""
              })`
            : "";
        return (
          <span
            className={"resist-cell" + (r.value === 0 ? " zero" : "") + (r.value < 0 ? " neg" : "")}
            key={r.label}
            title={`${r.label} Resistance${capNote}`}
            style={el ? { color: ELEMENT_COLOR[el] } : undefined}
          >
            {el && <ElementIcon element={el} size={16} />}
            <span className="resist-val">{fmtPct(r.value)}%</span>
          </span>
        );
      })}
    </div>
  );
}

// The in-game-style resistance grid: an icon + value per type in fixed columns.
// Pass entries already ordered (see `orderedResists`). `inline` switches to a
// flowing chip layout for compact item cards.
export function ResistRow({ entries, inline = false }: { entries: ResistEntry[]; inline?: boolean }) {
  return (
    <div className={inline ? "resist-row inline" : "resist-row"}>
      {entries.map((r) => {
        const el = ELEMENT_BY_LABEL.get(r.label) ?? elementOf(r.label);
        const capNote =
          r.cap !== undefined
            ? ` — ${fmtPct(r.value)}% (cap ${fmtPct(r.cap)}${
                r.overcap ? `, +${fmtPct(r.overcap)} over` : ""
              })`
            : "";
        return (
          <span
            className={"resist-chip" + (r.value === 0 ? " zero" : "") + (r.value < 0 ? " neg" : "")}
            key={r.label}
            title={`${r.label} Resistance${capNote}`}
            style={el ? { color: ELEMENT_COLOR[el] } : undefined}
          >
            {el && <ElementIcon element={el} />}
            <span className="resist-val">{fmtPct(r.value)}%</span>
          </span>
        );
      })}
    </div>
  );
}
