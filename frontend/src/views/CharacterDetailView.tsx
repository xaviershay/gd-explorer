import { useCallback, useState } from "react";
import {
    getCharacter,
    getEnhancements,
    getEnhancementRanking,
    Attack,
    Catalog,
    Gear,
    Overrides,
    ShoppingItem,
    StatSummary,
} from "../api";
import { useAsync, useAsyncKeep } from "../hooks";
import { elementColor, orderedResists, ResistRow } from "../elements";
import { ItemImage } from "../components/ItemImage";
import { ItemAttributes } from "../components/ItemAttributes";
import { EnhancementPicker } from "../components/EnhancementPicker";

const num = (n: number) => Math.round(n).toLocaleString();
const signed = (n: number) => (n > 0 ? "+" : "") + num(n);

export function CharacterDetailView({ name }: { name: string }) {
    const catalog = useAsync(getEnhancements, "enhancements");
    const [overrides, setOverrides] = useState<Overrides>({});
    const [maxLevel, setMaxLevel] = useState<number | null>(null);
    const char = useAsyncKeep(
        () => getCharacter(name, overrides),
        `character:${name}:${JSON.stringify(overrides)}`,
    );

    if (char.error) return <p className="error">{char.error}</p>;
    if (!char.data) return <p className="muted">Loading {name}…</p>;
    const c = char.data;
    const cat = catalog.status === "ok" ? catalog.data : undefined;
    // Default the component/augment level cap to the character's level.
    const effMax = maxLevel ?? c.level;

    const setSlot = (
        i: number,
        patch: { component?: string; augment?: string },
    ) => setOverrides((o) => ({ ...o, [i]: { ...o[i], ...patch } }));

    return (
        <>
            <p>
                <a href="#/characters">← Characters</a>
            </p>
            <h1>
                {c.name}{" "}
                <span className="muted">
                    — Level {c.level} {c.className}
                </span>
                {c.hardcore && <span className="badge">Hardcore</span>}
            </h1>

            <StickySummary summary={c.summary} />
            <SummaryPanel summary={c.summary} />
            <AttacksPanel attacks={c.attacks} />

            <h2 className="section-head">
                Equipped gear
                <label className="max-level">
                    Max level
                    <input
                        type="number"
                        min={1}
                        max={c.level}
                        value={effMax}
                        onChange={(e) =>
                            setMaxLevel(
                                Math.max(1, Number(e.target.value) || 1),
                            )
                        }
                    />
                </label>
                {Object.keys(overrides).length > 0 && (
                    <button
                        className="btn reset-overrides"
                        onClick={() => setOverrides({})}
                    >
                        Reset configuration
                    </button>
                )}
                {char.loading && (
                    <span className="muted updating"> updating…</span>
                )}
            </h2>
            {c.gear.length === 0 ? (
                <p className="muted">No equipped gear.</p>
            ) : (
                <EquipmentBody
                    name={name}
                    gear={c.gear}
                    catalog={cat}
                    maxLevel={effMax}
                    overrides={overrides}
                    onChange={setSlot}
                />
            )}

            <ShoppingList items={c.shopping} />
        </>
    );
}

// A compact, always-visible bar pinned to the top of the scroll area: the
// resistance icons and total damage bonuses, so configuration changes made
// further down show their impact without scrolling back up.
function StickySummary({ summary }: { summary: StatSummary }) {
    const resists = orderedResists(
        summary.resists.map((r) => ({
            label: r.name,
            value: r.value,
            cap: r.cap,
            overcap: r.overcap,
        })),
    );
    return (
        <div className="sticky-summary">
            <ResistRow entries={resists} inline />
            {summary.damage.length > 0 && (
                <div className="sticky-damage">
                    {summary.damage.map((l, i) => (
                        <span
                            key={i}
                            className="dtype"
                            style={{ color: elementColor(l) }}
                        >
                            {l}
                        </span>
                    ))}
                </div>
            )}
        </div>
    );
}

// What the current configuration needs that the saved character lacks.
function ShoppingList({ items }: { items: ShoppingItem[] }) {
    if (items.length === 0) return null;
    return (
        <>
            <h2 className="section-head">Shopping list</h2>
            <p className="muted">
                Components and augments in this configuration that your saved
                character doesn't have.
            </p>
            <ul className="shopping">
                {items.map((s, i) => (
                    <li className="shop-item" key={i}>
                        <ItemImage record={s.record} />
                        <div className="shop-body">
                            <div className="shop-name">
                                {s.name}
                                {s.count > 1 && (
                                    <span className="muted"> ×{s.count}</span>
                                )}
                            </div>
                            <div className="shop-meta muted">
                                {s.kind === "component"
                                    ? "Component"
                                    : "Augment"}
                                {s.source
                                    ? ` · ${s.source}`
                                    : s.kind === "component"
                                      ? " · crafted or found"
                                      : " · faction vendor"}
                            </div>
                        </div>
                    </li>
                ))}
            </ul>
        </>
    );
}

// The equipment "paper doll": a top row of rings/head/amulet, two columns of
// weapons + armour, then a bottom row of relic/waist/medal. Each cell carries
// the item's icon, full stats, and component/augment selectors; empty slots show
// a faint placeholder so positions stay stable across characters.
const TOP_ROW = ["ring1", "head", "amulet", "ring2"];
const MID_LEFT = ["weapon1", "chest", "legs"];
const MID_RIGHT = ["weapon2", "shoulders", "hands", "feet"];
const BOTTOM_ROW = ["relic", "waist", "medal"];
const ALL_AREAS = [...TOP_ROW, ...MID_LEFT, ...MID_RIGHT, ...BOTTOM_ROW];

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
    weapon1: "Main hand",
    weapon2: "Off-hand",
};

type SlotChange = (
    i: number,
    patch: { component?: string; augment?: string },
) => void;
interface Placed {
    gear: Gear;
    index: number; // index into the original gear list (override addressing)
}

// Map a gear `type` to its layout slot category.
function slotCategory(type: string | null): string {
    const t = (type ?? "").toLowerCase();
    if (["chest", "torso"].includes(t)) return "chest";
    if (["waist", "belt"].includes(t)) return "waist";
    if (["amulet", "neck", "necklace"].includes(t)) return "amulet";
    if (["itemartifact", "relic"].includes(t)) return "relic";
    if (
        [
            "head",
            "shoulders",
            "hands",
            "legs",
            "feet",
            "medal",
            "ring",
        ].includes(t)
    )
        return t;
    return "weapon"; // any weapon/off-hand type (sword2h, ranged2h, shield, caster, …)
}

// The slot-compatibility flag a component/augment must declare for this gear, or
// null when the slot takes none (relics).
function slotFlag(type: string | null): string | null {
    const t = (type ?? "").toLowerCase();
    if (t === "itemartifact" || t === "relic") return null;
    const alias: Record<string, string> = {
        torso: "chest",
        belt: "waist",
        neck: "amulet",
        necklace: "amulet",
    };
    return alias[t] ?? t;
}

function assignSlots(gear: Gear[]): Map<string, Placed> {
    const slots = new Map<string, Placed>();
    let ring = 0;
    let weapon = 0;
    gear.forEach((g, index) => {
        const cat = slotCategory(g.type);
        const area =
            cat === "ring"
                ? `ring${++ring}`
                : cat === "weapon"
                  ? `weapon${++weapon}`
                  : cat;
        if (!slots.has(area)) slots.set(area, { gear: g, index });
    });
    return slots;
}

function EquipmentBody({
    name,
    gear,
    catalog,
    maxLevel,
    overrides,
    onChange,
}: {
    name: string;
    gear: Gear[];
    catalog?: Catalog;
    maxLevel: number;
    overrides: Overrides;
    onChange: SlotChange;
}) {
    const slots = assignSlots(gear);
    const placed = new Set(ALL_AREAS);
    const extras = [...slots.entries()]
        .filter(([a]) => !placed.has(a))
        .map(([, p]) => p);
    const cells = (areas: string[], className: string) => (
        <EquipCells
            areas={areas}
            className={className}
            slots={slots}
            catalog={catalog}
            maxLevel={maxLevel}
            name={name}
            overrides={overrides}
            onChange={onChange}
        />
    );
    return (
        <>
            {cells(TOP_ROW, "equip-row equip-row-4")}
            <div className="equip-body-mid">
                {cells(MID_LEFT, "equip-col")}
                {cells(MID_RIGHT, "equip-col")}
            </div>
            {cells(BOTTOM_ROW, "equip-row equip-row-3")}
            {extras.length > 0 && (
                <div className="equip-extras">
                    {extras.map((p) => (
                        <EquipCard
                            key={p.index}
                            placed={p}
                            catalog={catalog}
                            maxLevel={maxLevel}
                            name={name}
                            overrides={overrides}
                            onChange={onChange}
                        />
                    ))}
                </div>
            )}
        </>
    );
}

function EquipCells({
    areas,
    className,
    slots,
    catalog,
    maxLevel,
    name,
    overrides,
    onChange,
}: {
    areas: string[];
    className: string;
    slots: Map<string, Placed>;
    catalog?: Catalog;
    maxLevel: number;
    name: string;
    overrides: Overrides;
    onChange: SlotChange;
}) {
    return (
        <div className={className}>
            {areas.map((area) => {
                const p = slots.get(area);
                return p ? (
                    <EquipCard
                        key={area}
                        placed={p}
                        catalog={catalog}
                        maxLevel={maxLevel}
                        name={name}
                        overrides={overrides}
                        onChange={onChange}
                    />
                ) : (
                    <div className="equip-empty" key={area}>
                        {SLOT_LABEL[area]}
                    </div>
                );
            })}
        </div>
    );
}

function EquipCard({
    placed,
    catalog,
    maxLevel,
    name,
    overrides,
    onChange,
}: {
    placed: Placed;
    catalog?: Catalog;
    maxLevel: number;
    name: string;
    overrides: Overrides;
    onChange: SlotChange;
}) {
    const { gear, index } = placed;
    const flag = slotFlag(gear.type);
    const fits = (e: { slots: string[]; level: number | null }) =>
        e.slots.includes(flag ?? "") && (e.level ?? 0) <= maxLevel;
    // Per-kind ranking fetchers, memoised by (name, index, overrides) so the
    // picker's cache stays valid until the build actually changes.
    const fetchComponentRanking = useCallback(
        () => getEnhancementRanking(name, index, "component", overrides),
        [name, index, overrides],
    );
    const fetchAugmentRanking = useCallback(
        () => getEnhancementRanking(name, index, "augment", overrides),
        [name, index, overrides],
    );
    return (
        <div className="equip-card">
            <ItemImage record={gear.record} />
            <div className="pin-body">
                <ItemAttributes gear={gear} />
                {catalog && flag && (
                    <div className="enh-controls">
                        <EnhancementPicker
                            label="Component"
                            current={gear.component}
                            options={catalog.components.filter(fits)}
                            onChange={(v) => onChange(index, { component: v })}
                            fetchRanking={fetchComponentRanking}
                        />
                        <EnhancementPicker
                            label="Augment"
                            current={gear.augment}
                            options={catalog.augments.filter(fits)}
                            onChange={(v) => onChange(index, { augment: v })}
                            fetchRanking={fetchAugmentRanking}
                        />
                    </div>
                )}
            </div>
        </div>
    );
}

// Overall stats: resistance icon grid, attributes, and key offensive/defensive
// totals (gear + devotions + mastery + always-on buffs).
function SummaryPanel({ summary }: { summary: StatSummary }) {
    const resists = orderedResists(
        summary.resists.map((r) => ({
            label: r.name,
            value: r.value,
            cap: r.cap,
            overcap: r.overcap,
        })),
    );
    return (
        <div className="summary-panel">
            <div className="summary-block">
                <div className="summary-head">
                    Resistances{" "}
                    <span className="muted">({summary.difficulty})</span>
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
                                    {k.pct !== 0 && (
                                        <span className="muted">
                                            {" "}
                                            ({signed(k.pct)}%)
                                        </span>
                                    )}
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
                Incorporates skills, devotions &amp; always-on buffs;
                conversions and stacking DoTs applied. Assumed base attack
                speed; no crit or enemy resistances.
            </p>
            {active.length > 0 && (
                <div className="attacks-total">
                    Best attack ~{num(best)}
                    {procSum > 0 && (
                        <>
                            {" "}
                            + procs ~{num(procSum)} ={" "}
                            <strong>~{num(best + procSum)} dps</strong>
                        </>
                    )}
                    {procSum === 0 && <strong> dps</strong>}
                </div>
            )}
            <div className="attack-grid">
                {active.length > 0 && (
                    <div className="attacks-sub">Attacks (pick one)</div>
                )}
                {active.map((a, i) => (
                    <AttackCard key={i} a={a} />
                ))}
                {procs.length > 0 && (
                    <div className="attacks-sub">
                        Procs (auto, while attacking)
                    </div>
                )}
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
                    {a.rank != null && (
                        <span className="muted"> ({a.rank})</span>
                    )}
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
                    <span
                        key={i}
                        className="dtype"
                        style={{ color: elementColor(t.label) }}
                    >
                        {t.label} {num(t.value)}
                    </span>
                ))}
            </div>
        </div>
    );
}
