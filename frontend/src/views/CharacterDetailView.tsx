import { getCharacter, Attack, Gear, StatSummary } from "../api";
import { useAsync } from "../hooks";
import { rarityColor } from "../colors";
import { BonusItem, elementColor, orderedResists, ResistRow } from "../elements";
import { ItemImage } from "../components/ItemImage";

const num = (n: number) => Math.round(n).toLocaleString();
const signed = (n: number) => (n > 0 ? "+" : "") + num(n);

export function CharacterDetailView({ name }: { name: string }) {
  const state = useAsync(() => getCharacter(name), `character:${name}`);
  if (state.status === "loading") return <p className="muted">Loading {name}…</p>;
  if (state.status === "error") return <p className="error">{state.error}</p>;

  const c = state.data;
  return (
    <>
      <p>
        <a href="#/characters">← Characters</a>
      </p>
      <h1>
        {c.name} <span className="muted">— Level {c.level} {c.className}</span>
        {c.hardcore && <span className="badge">Hardcore</span>}
      </h1>

      <SummaryPanel summary={c.summary} />
      <AttacksPanel attacks={c.attacks} />

      <h2 className="section-head">Equipped gear</h2>
      {c.gear.length === 0 ? (
        <p className="muted">No equipped gear.</p>
      ) : (
        <>
          <EquipmentGrid gear={c.gear} />
          {c.gear.map((g, i) => (
            <GearItem key={i} gear={g} />
          ))}
        </>
      )}
    </>
  );
}

// A paper-doll grid approximating the in-game equipment layout: armour down the
// left, jewellery + weapons down the right (amulet beside the head, etc.).
const SLOT_LAYOUT = [
  "head",
  "amulet",
  "shoulders",
  "medal",
  "chest",
  "ring1",
  "hands",
  "ring2",
  "legs",
  "relic",
  "waist",
  "weapon1",
  "feet",
  "weapon2",
];
const SLOT_LABEL: Record<string, string> = {
  head: "Head",
  shoulders: "Shoulders",
  chest: "Chest",
  hands: "Hands",
  legs: "Legs",
  waist: "Waist",
  feet: "Feet",
  amulet: "Amulet",
  medal: "Medal",
  ring1: "Ring",
  ring2: "Ring",
  relic: "Relic",
  weapon1: "Weapon",
  weapon2: "Off-hand",
};

// Map a gear `type` to its layout slot category.
function slotCategory(type: string | null): string {
  const t = (type ?? "").toLowerCase();
  if (["chest", "torso"].includes(t)) return "chest";
  if (["waist", "belt"].includes(t)) return "waist";
  if (["amulet", "neck", "necklace"].includes(t)) return "amulet";
  if (["itemartifact", "relic"].includes(t)) return "relic";
  if (["head", "shoulders", "hands", "legs", "feet", "medal", "ring"].includes(t)) return t;
  return "weapon"; // any weapon/off-hand type (sword2h, ranged2h, shield, caster, …)
}

function assignSlots(gear: Gear[]): Map<string, Gear> {
  const slots = new Map<string, Gear>();
  let ring = 0;
  let weapon = 0;
  for (const g of gear) {
    const cat = slotCategory(g.type);
    const area = cat === "ring" ? `ring${++ring}` : cat === "weapon" ? `weapon${++weapon}` : cat;
    if (!slots.has(area)) slots.set(area, g);
  }
  return slots;
}

function EquipmentGrid({ gear }: { gear: Gear[] }) {
  const slots = assignSlots(gear);
  return (
    <div className="equip-grid">
      {SLOT_LAYOUT.map((area) => {
        const g = slots.get(area);
        return (
          <div className="equip-slot" key={area} style={{ gridArea: area }}>
            {g ? (
              <>
                <ItemImage record={g.record} />
                <div className="equip-info">
                  <div className="equip-name" style={{ color: rarityColor(g.classification) }}>
                    {g.name}
                  </div>
                  <div className="equip-meta muted">
                    {SLOT_LABEL[area]}
                    {g.levelRequirement ? ` · lvl ${g.levelRequirement}` : ""}
                  </div>
                </div>
              </>
            ) : (
              <div className="equip-empty muted">{SLOT_LABEL[area]}</div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// Overall stats: resistance icon grid, attributes, and key offensive/defensive
// totals (gear + devotions + mastery + always-on buffs).
function SummaryPanel({ summary }: { summary: StatSummary }) {
  const resists = orderedResists(
    summary.resists.map((r) => ({ label: r.name, value: r.value, cap: r.cap, overcap: r.overcap })),
  );
  return (
    <div className="summary-panel">
      <div className="summary-block">
        <div className="summary-head">
          Resistances <span className="muted">({summary.difficulty})</span>
        </div>
        <ResistRow entries={resists} />
      </div>
      <div className="summary-cols">
        <div className="summary-block">
          <div className="summary-head">Attributes</div>
          <ul className="stat-list">
            {summary.attributes.map((a) => (
              <li key={a.label}>
                <span className="stat-label">{a.label}</span>
                <span className="stat-val">{num(a.value)}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="summary-block">
          <div className="summary-head">Defense &amp; Offense</div>
          <ul className="stat-list">
            {summary.keyTotals.map((k) => (
              <li key={k.label}>
                <span className="stat-label">{k.label}</span>
                <span className="stat-val">
                  {signed(k.flat)}
                  {k.pct !== 0 && <span className="muted"> ({signed(k.pct)}%)</span>}
                </span>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}

// Estimated attack/proc DPS, mirroring the `dps` CLI command.
function AttacksPanel({ attacks }: { attacks: Attack[] }) {
  const active = attacks.filter((a) => a.kind === "active");
  const procs = attacks.filter((a) => a.kind === "proc");
  if (active.length === 0 && procs.length === 0) return null;

  const best = active.reduce((m, a) => Math.max(m, a.dps), 0);
  const procSum = procs.reduce((s, a) => s + a.dps, 0);

  return (
    <>
      <h2 className="section-head">Attack DPS estimate</h2>
      <p className="muted">
        Incorporates skills, devotions &amp; always-on buffs; conversions and stacking DoTs
        applied. Assumed base attack speed; no crit or enemy resistances.
      </p>
      {active.length > 0 && (
        <div className="attacks-total">
          Best attack ~{num(best)}
          {procSum > 0 && (
            <>
              {" "}
              + procs ~{num(procSum)} = <strong>~{num(best + procSum)} dps</strong>
            </>
          )}
          {procSum === 0 && <strong> dps</strong>}
        </div>
      )}
      <div className="attack-grid">
        {active.length > 0 && <div className="attacks-sub">Attacks (pick one)</div>}
        {active.map((a, i) => (
          <AttackCard key={i} a={a} />
        ))}
        {procs.length > 0 && <div className="attacks-sub">Procs (auto, while attacking)</div>}
        {procs.map((a, i) => (
          <AttackCard key={i} a={a} />
        ))}
      </div>
    </>
  );
}

function AttackCard({ a }: { a: Attack }) {
  return (
    <div className="attack-card">
      <div className="attack-row">
        <span className="attack-name">
          {a.name}
          {a.rank != null && <span className="muted"> ({a.rank})</span>}
        </span>
        <span className="attack-dps">
          {num(a.dps)} <span className="muted">dps</span>
        </span>
      </div>
      <div className="attack-meta muted">
        per-hit {num(a.perHit)} · {a.rate}
      </div>
      <div className="attack-types">
        {a.types.map((t, i) => (
          <span key={i} className="dtype" style={{ color: elementColor(t.label) }}>
            {t.label} {num(t.value)}
          </span>
        ))}
      </div>
    </div>
  );
}

function GearItem({ gear }: { gear: Gear }) {
  const lines = [
    ...gear.resistBonuses,
    ...gear.damageBonuses,
    ...gear.bonuses,
    ...gear.skillBonuses,
  ];
  return (
    <div className="gear">
      <div className="gear-name" style={{ color: rarityColor(gear.classification) }}>
        {gear.name}
        {gear.isSet && <span className="badge">Set</span>}
      </div>
      <div className="gear-meta">
        {[gear.type, gear.classification, gear.levelRequirement ? `lvl ${gear.levelRequirement}` : null]
          .filter(Boolean)
          .join(" · ")}
      </div>
      {lines.length > 0 && (
        <ul>
          {lines.map((l, i) => (
            <BonusItem key={i} line={l} />
          ))}
        </ul>
      )}
    </div>
  );
}
