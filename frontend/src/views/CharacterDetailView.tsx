import { useCallback, useEffect, useState } from "react";
import {
    getCharacter,
    getEnhancements,
    getEnhancementRanking,
    getItemRanking,
    Attack,
    Catalog,
    ConstellationEntry,
    DamageRow,
    Difficulty,
    Gear,
    MasteryGroup,
    NamedValue,
    Overrides,
    ShoppingItem,
    StatSummary,
} from "../api";
import { useAsync, useAsyncKeep } from "../hooks";
import {
    ELEMENT_COLOR,
    RESISTANCES,
    ElementIcon,
    elementColor,
    elementOf,
} from "../elements";
import { groupBonuses, GroupedStats } from "../bonuses";
import { ItemImage } from "../components/ItemImage";
import { ItemAttributes } from "../components/ItemAttributes";
import { EnhancementPicker } from "../components/EnhancementPicker";
import { ItemPicker } from "../components/ItemPicker";

const num = (n: number) => Math.round(n).toLocaleString();

// Persisted per-character configuration (overrides + difficulty + max-level
// cap) keyed by character name.  Survives reloads so the user doesn't have to
// reconstruct a what-if every time they revisit a character.
const STORAGE_PREFIX = "gdx.charcfg.";
interface PersistedConfig {
    overrides: Overrides;
    difficulty: Difficulty;
    maxLevel: number | null;
}
function loadConfig(name: string): PersistedConfig | null {
    try {
        const raw = localStorage.getItem(STORAGE_PREFIX + name);
        if (!raw) return null;
        const parsed = JSON.parse(raw);
        // Light validation so a malformed entry doesn't crash the page.
        if (!parsed || typeof parsed !== "object") return null;
        return {
            overrides: parsed.overrides ?? {},
            difficulty: parsed.difficulty ?? "ultimate",
            maxLevel: parsed.maxLevel ?? null,
        };
    } catch {
        return null;
    }
}
function saveConfig(name: string, cfg: PersistedConfig) {
    try {
        // Drop empty-equivalent state so we don't litter storage with defaults.
        const isDefault =
            Object.keys(cfg.overrides).length === 0 &&
            cfg.difficulty === "ultimate" &&
            cfg.maxLevel === null;
        if (isDefault) localStorage.removeItem(STORAGE_PREFIX + name);
        else localStorage.setItem(STORAGE_PREFIX + name, JSON.stringify(cfg));
    } catch {
        /* storage full or disabled — ignore */
    }
}

export function CharacterDetailView({ name }: { name: string }) {
    const catalog = useAsync(getEnhancements, "enhancements");
    // Hydrate persisted config once per character switch; the lazy initialiser
    // means the first render already reflects the saved state.
    const initial = loadConfig(name);
    const [overrides, setOverrides] = useState<Overrides>(
        () => initial?.overrides ?? {},
    );
    const [maxLevel, setMaxLevel] = useState<number | null>(
        () => initial?.maxLevel ?? null,
    );
    const [difficulty, setDifficulty] = useState<Difficulty>(
        () => initial?.difficulty ?? "ultimate",
    );
    // If the user navigates to a different character, re-load that character's
    // persisted config (the lazy initialisers above only fire on mount).
    useEffect(() => {
        const cfg = loadConfig(name);
        setOverrides(cfg?.overrides ?? {});
        setMaxLevel(cfg?.maxLevel ?? null);
        setDifficulty(cfg?.difficulty ?? "ultimate");
    }, [name]);
    // Persist on any change.
    useEffect(() => {
        saveConfig(name, { overrides, difficulty, maxLevel });
    }, [name, overrides, difficulty, maxLevel]);

    const char = useAsyncKeep(
        () => getCharacter(name, overrides, difficulty),
        `character:${name}:${difficulty}:${JSON.stringify(overrides)}`,
    );

    if (char.error) return <p className="error">{char.error}</p>;
    if (!char.data) return <p className="muted">Loading {name}…</p>;
    const c = char.data;
    const cat = catalog.status === "ok" ? catalog.data : undefined;
    // Default the component/augment level cap to the character's level.
    const effMax = maxLevel ?? c.level;

    const setSlot = (
        i: number,
        patch: { item?: string; component?: string; augment?: string },
    ) => setOverrides((o) => ({ ...o, [i]: { ...o[i], ...patch } }));

    // Drop the override for a single gear slot (per-card "reset" button).
    const resetSlot = (i: number) =>
        setOverrides((o) => {
            const next = { ...o };
            delete next[i];
            return next;
        });
    const resetAll = () => {
        setOverrides({});
        setMaxLevel(null);
        setDifficulty("ultimate");
    };

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
                <label className="difficulty-select">
                    <span className="muted">Difficulty</span>
                    <select
                        value={difficulty}
                        onChange={(e) =>
                            setDifficulty(e.target.value as Difficulty)
                        }
                    >
                        <option value="normal">Normal (0)</option>
                        <option value="elite">Elite (-25%)</option>
                        <option value="ultimate">Ultimate (-50%)</option>
                    </select>
                </label>
            </h1>

            <SummaryPanel
                summary={c.summary}
                attacks={c.attacks}
                armorTable={c.armorTable}
            />
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
                        onClick={resetAll}
                        title="Clear overrides, max-level cap, and difficulty"
                    >
                        Reset all
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
                    difficulty={difficulty}
                    onChange={setSlot}
                    onReset={resetSlot}
                />
            )}

            <ShoppingList items={c.shopping} />
            <SkillsPanel masteries={c.masteries ?? []} />
            <DevotionsPanel devotions={c.devotions ?? []} />
        </>
    );
}

// Friendly label for a gear slot type (the lowercased subtype returned by
// the backend, e.g. "sword2h" or "ring"). Used by shopping-list entries to
// remind the user which slot each enhancement belongs on.
function slotTypeLabel(t: string): string {
    const overrides: Record<string, string> = {
        sword2h: "2H Sword",
        axe2h: "2H Axe",
        mace2h: "2H Mace",
        spear2h: "2H Spear",
        ranged1h: "1H Ranged",
        ranged2h: "2H Ranged",
        offhand: "Off-hand",
    };
    if (overrides[t]) return overrides[t];
    return t.charAt(0).toUpperCase() + t.slice(1);
}

// What the current configuration needs that the saved character lacks. Augments
// are grouped by their faction vendor (so you can do one shop run per faction);
// components fall into a single “crafted or found” bucket. Each entry shows
// which gear slot(s) it's intended for.
// Group shopping entries by their `source`, with a stable alphabetical order.
function groupBySource(items: ShoppingItem[], fallback: string) {
    const groups = new Map<string, ShoppingItem[]>();
    for (const it of items) {
        const key = it.source ?? fallback;
        const bucket = groups.get(key);
        if (bucket) bucket.push(it);
        else groups.set(key, [it]);
    }
    return Array.from(groups.entries()).sort(([a], [b]) => a.localeCompare(b));
}

const STANDING_ORDER: Record<string, number> = {
    Friendly: 0,
    Respected: 1,
    Honored: 2,
    Revered: 3,
};

// Group augments by "faction · standing" key, sorted faction-alpha then tier-ascending.
function groupAugments(items: ShoppingItem[]) {
    const groups = new Map<string, ShoppingItem[]>();
    for (const it of items) {
        const faction = it.source ?? "Unknown vendor";
        const tier = it.standing ?? "";
        const key = tier ? `${faction}\x00${tier}` : faction;
        const bucket = groups.get(key);
        if (bucket) bucket.push(it);
        else groups.set(key, [it]);
    }
    return Array.from(groups.entries())
        .sort(([a], [b]) => {
            const [af, at = ""] = a.split("\x00");
            const [bf, bt = ""] = b.split("\x00");
            const fc = af.localeCompare(bf);
            if (fc !== 0) return fc;
            return (STANDING_ORDER[at] ?? 99) - (STANDING_ORDER[bt] ?? 99);
        })
        .map(([key, group]) => {
            const [faction, tier] = key.split("\x00");
            const label = tier ? `${faction} · ${tier}` : faction;
            return [label, group] as [string, ShoppingItem[]];
        });
}

function ShoppingList({ items }: { items: ShoppingItem[] }) {
    if (items.length === 0) return null;
    // Items to acquire (owned elsewhere) first, then components, then augments by
    // vendor — each grouped by where it comes from.
    const itemGroups = groupBySource(
        items.filter((s) => s.kind === "item"),
        "Unknown location",
    );
    const componentItems = items.filter((s) => s.kind === "component");
    const augmentGroups = groupAugments(
        items.filter((s) => s.kind === "augment"),
    );
    return (
        <>
            <h2 className="section-head">Shopping list</h2>
            <p className="muted">
                Items, components and augments in this configuration that aren't
                equipped on your saved character.
            </p>
            {itemGroups.map(([source, group]) => (
                <ShoppingGroup
                    key={"item:" + source}
                    title={source}
                    subtitle="owned — equip from here"
                    items={group}
                />
            ))}
            {componentItems.length > 0 && (
                <ShoppingGroup
                    title="Components"
                    subtitle="crafted or found"
                    items={componentItems}
                />
            )}
            {augmentGroups.map(([source, group]) => (
                <ShoppingGroup
                    key={"aug:" + source}
                    title={source}
                    subtitle="faction vendor"
                    items={group}
                />
            ))}
        </>
    );
}

function ShoppingGroup({
    title,
    subtitle,
    items,
}: {
    title: string;
    subtitle?: string;
    items: ShoppingItem[];
}) {
    return (
        <div className="shop-group">
            <div className="shop-group-head">
                {title}
                {subtitle && <span className="muted"> · {subtitle}</span>}
            </div>
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
                            {s.slots.length > 0 && (
                                <div className="shop-meta muted">
                                    {s.slots.map(slotTypeLabel).join(", ")}
                                </div>
                            )}
                        </div>
                    </li>
                ))}
            </ul>
        </div>
    );
}

// The equipment "paper doll": a simple 7-row × 2-column grid (row-major), each
// row a sensible pair — head|amulet, the two rings, then armour, waist|boots,
// weapons, and relic|medal. Each cell carries the item's icon, full stats, and
// item/component/augment selectors; empty slots show a faint placeholder so
// positions stay stable across characters.
const SLOT_ORDER = [
    "head",
    "amulet",
    "ring1",
    "ring2",
    "shoulders",
    "chest",
    "hands",
    "legs",
    "waist",
    "feet",
    "weapon1",
    "weapon2",
    "relic",
    "medal",
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
    weapon1: "Main hand",
    weapon2: "Off-hand",
};

type SlotChange = (
    i: number,
    patch: { item?: string; component?: string; augment?: string },
) => void;
type SlotReset = (i: number) => void;
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
    difficulty,
    onChange,
    onReset,
}: {
    name: string;
    gear: Gear[];
    catalog?: Catalog;
    maxLevel: number;
    overrides: Overrides;
    difficulty: Difficulty;
    onChange: SlotChange;
    onReset: SlotReset;
}) {
    const slots = assignSlots(gear);
    const placed = new Set(SLOT_ORDER);
    const extras = [...slots.entries()]
        .filter(([a]) => !placed.has(a))
        .map(([, p]) => p);
    return (
        <>
            <EquipCells
                areas={SLOT_ORDER}
                className="equip-grid2"
                slots={slots}
                catalog={catalog}
                maxLevel={maxLevel}
                name={name}
                overrides={overrides}
                difficulty={difficulty}
                onChange={onChange}
                onReset={onReset}
            />
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
                            difficulty={difficulty}
                            onChange={onChange}
                            onReset={onReset}
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
    difficulty,
    onChange,
    onReset,
}: {
    areas: string[];
    className: string;
    slots: Map<string, Placed>;
    catalog?: Catalog;
    maxLevel: number;
    name: string;
    overrides: Overrides;
    difficulty: Difficulty;
    onChange: SlotChange;
    onReset: SlotReset;
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
                        difficulty={difficulty}
                        onChange={onChange}
                        onReset={onReset}
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
    difficulty,
    onChange,
    onReset,
}: {
    placed: Placed;
    catalog?: Catalog;
    maxLevel: number;
    name: string;
    overrides: Overrides;
    difficulty: Difficulty;
    onChange: SlotChange;
    onReset: SlotReset;
}) {
    const { gear, index } = placed;
    const flag = slotFlag(gear.type);
    const fits = (e: { slots: string[]; level: number | null }) =>
        e.slots.includes(flag ?? "") && (e.level ?? 0) <= maxLevel;
    // Per-kind ranking fetchers, memoised by (name, index, overrides, difficulty)
    // so the picker's cache stays valid until the build actually changes.
    const fetchComponentRanking = useCallback(
        () =>
            getEnhancementRanking(
                name,
                index,
                "component",
                overrides,
                difficulty,
            ),
        [name, index, overrides, difficulty],
    );
    const fetchAugmentRanking = useCallback(
        () =>
            getEnhancementRanking(
                name,
                index,
                "augment",
                overrides,
                difficulty,
            ),
        [name, index, overrides, difficulty],
    );
    const fetchItemRanking = useCallback(
        () => getItemRanking(name, index, overrides, difficulty),
        [name, index, overrides, difficulty],
    );
    const slotHasOverride = overrides[index] !== undefined;
    return (
        <div className="equip-card">
            <ItemImage record={gear.record} />
            <div className="pin-body">
                <ItemAttributes gear={gear} resistTable />
                <div className="enh-controls">
                    {slotHasOverride && (
                        <button
                            className="btn reset-slot"
                            onClick={() => onReset(index)}
                            title="Restore this slot's saved item, component & augment"
                        >
                            Reset slot
                        </button>
                    )}
                    <ItemPicker
                        current={gear.record}
                        currentName={gear.name}
                        currentClassification={gear.classification}
                        maxLevel={maxLevel}
                        fetchItems={fetchItemRanking}
                        onChange={(v) => onChange(index, { item: v })}
                    />
                    {catalog && flag && (
                        <>
                            <EnhancementPicker
                                label="Component"
                                current={gear.component}
                                options={catalog.components.filter(fits)}
                                onChange={(v) =>
                                    onChange(index, { component: v })
                                }
                                fetchRanking={fetchComponentRanking}
                            />
                            <EnhancementPicker
                                label="Augment"
                                current={gear.augment}
                                options={catalog.augments.filter(fits)}
                                onChange={(v) =>
                                    onChange(index, { augment: v })
                                }
                                fetchRanking={fetchAugmentRanking}
                            />
                        </>
                    )}
                </div>
            </div>
        </div>
    );
}

// Two side-by-side tables (5 rows each) merging resist% and damage stats per
// element. Left: fire/cold/lightning/acid/pierce. Right: bleed/vitality/aether/chaos/physical.
function MergedStatsTable({
    resists,
    damage,
}: {
    resists: StatSummary["resists"];
    damage: DamageRow[];
    difficulty: string;
}) {
    const resistByEl = new Map(
        resists.map((r) => [elementOf(r.name), r] as const),
    );
    const damageByEl = new Map(
        damage.map((d) => [elementOf(d.type), d] as const),
    );
    const fmtResist = (v: number) =>
        Number.isInteger(v) ? String(v) : v.toFixed(1);
    // Apply % bonus to flat base; blank when no base exists.
    const fmtEffective = (lo: number, hi: number, pct: number) => {
        if (hi <= 0) return "";
        const m = 1 + pct / 100;
        const a = Math.round(lo * m);
        const b = Math.round(hi * m);
        return a === b ? String(a) : `${a}–${b}`;
    };

    const renderHalf = (half: (typeof RESISTANCES)[number][]) => (
        <table className="element-table">
            <thead>
                <tr>
                    <th />
                    <th title="Resistance">🛡</th>
                    <th>⚔</th>
                    <th>Δ</th>
                </tr>
            </thead>
            <tbody>
                {half.map(({ label: elLabel, element }) => {
                    const r = resistByEl.get(element);
                    const d = damageByEl.get(element);
                    const rv = r?.value ?? 0;
                    const title =
                        r && r.cap !== undefined
                            ? `${elLabel}: ${fmtResist(rv)}% (cap ${fmtResist(r.cap)}${r.overcap ? `, +${fmtResist(r.overcap)} over` : ""})`
                            : elLabel;
                    return (
                        <tr
                            key={element}
                            style={{ color: ELEMENT_COLOR[element] }}
                        >
                            <td className="el-icon" title={title}>
                                <ElementIcon element={element} size={14} />
                            </td>
                            <td
                                className={
                                    "el-resist" + (rv === 0 ? " zero" : "")
                                }
                                title={title}
                            >
                                {fmtResist(rv)}%
                                {r && r.overcap > 0 && (
                                    <span className="muted">
                                        {" "}
                                        (+{fmtResist(r.overcap)})
                                    </span>
                                )}
                            </td>
                            <td className="el-num">
                                {d
                                    ? fmtEffective(
                                          d.instFlatLo,
                                          d.instFlatHi,
                                          d.instPct,
                                      )
                                    : ""}
                            </td>
                            <td className="el-num">
                                {d
                                    ? fmtEffective(
                                          d.dotFlatLo,
                                          d.dotFlatHi,
                                          d.dotPct,
                                      )
                                    : ""}
                            </td>
                        </tr>
                    );
                })}
            </tbody>
        </table>
    );

    return (
        <div className="element-tables">
            {renderHalf(RESISTANCES.slice(0, 5))}
            {renderHalf(RESISTANCES.slice(5))}
        </div>
    );
}

// Overall stats: resistance icon grid, attributes, and key offensive/defensive
// totals (gear + devotions + mastery + always-on buffs). Pinned to the top of
// the viewport while scrolling so configuration changes made further down show
// their impact without scrolling back up.
function SummaryPanel({
    summary,
    attacks,
    armorTable,
}: {
    summary: StatSummary;
    attacks: Attack[];
    armorTable: NamedValue[];
}) {
    const active = attacks.filter((a) => a.kind === "active");
    const procs = attacks.filter((a) => a.kind === "proc");
    const best = active.reduce((m, a) => Math.max(m, a.dps), 0);
    const procSum = procs.reduce((s, a) => s + a.dps, 0);
    return (
        <div className="summary-panel">
            <div className="summary-body">
                <div className="summary-lhs">
                    <div className="element-tables">
                        <table className="element-table">
                            <tbody>
                                {best > 0 && (
                                    <tr>
                                        <td className="el-label">DPS</td>
                                        <td>{num(best + procSum)}</td>
                                    </tr>
                                )}
                                <tr>
                                    <td className="el-label">Health</td>
                                    <td>{num(summary.health)}</td>
                                </tr>
                                <tr>
                                    <td className="el-label">Energy</td>
                                    <td>{num(summary.energy)}</td>
                                </tr>
                                {summary.oa > 0 && (
                                    <tr>
                                        <td className="el-label">OA</td>
                                        <td>{num(summary.oa)}</td>
                                    </tr>
                                )}
                                {summary.da > 0 && (
                                    <tr>
                                        <td className="el-label">DA</td>
                                        <td>{num(summary.da)}</td>
                                    </tr>
                                )}
                            </tbody>
                        </table>
                    </div>
                </div>
                <div className="summary-rhs">
                    <MergedStatsTable
                        resists={summary.resists}
                        damage={summary.damageTable}
                        difficulty={summary.difficulty}
                    />
                </div>
                {armorTable.length > 0 && (
                    <div className="element-tables">
                        <table className="element-table">
                            <tbody>
                                {armorTable.map((r) => (
                                    <tr key={r.label}>
                                        <td className="el-label">{r.label}</td>
                                        <td>{num(r.value)}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
                {summary.ccResists.length > 0 && (
                    <div className="element-tables">
                        <table className="element-table">
                            <tbody>
                                {summary.ccResists.map((r) => (
                                    <tr key={r.name}>
                                        <td className="el-label">{r.name}</td>
                                        <td
                                            title={`${r.name}: ${Math.round(r.value)}% (cap ${Math.round(r.cap)}${r.overcap ? `, +${Math.round(r.overcap)} over` : ""})`}
                                        >
                                            {Math.round(r.value)}%
                                            {r.overcap > 0 && (
                                                <span className="muted">
                                                    {" "}
                                                    (+{Math.round(r.overcap)})
                                                </span>
                                            )}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </div>
        </div>
    );
}

function SkillsPanel({ masteries }: { masteries: MasteryGroup[] }) {
    if (masteries.length === 0) return null;
    return (
        <>
            <h2 className="section-head">Skills</h2>
            <div className="skills-grid">
                {masteries.map((m) => (
                    <div key={m.name} className="mastery-card">
                        <div className="mastery-head">
                            {m.name}
                            <span className="muted"> ({m.rank})</span>
                        </div>
                        <ul className="skill-list">
                            {m.skills.map((s) => (
                                <li key={s.name} className="skill-entry">
                                    <span className="skill-rank">{s.rank}</span>
                                    <span className="skill-name">{s.name}</span>
                                </li>
                            ))}
                        </ul>
                    </div>
                ))}
            </div>
        </>
    );
}

function DevotionsPanel({ devotions }: { devotions: ConstellationEntry[] }) {
    if (devotions.length === 0) return null;
    const total = devotions.reduce((s, d) => s + d.stars, 0);
    return (
        <>
            <h2 className="section-head">
                Devotions
                <span className="muted"> — {total} points</span>
            </h2>
            <div className="devotions-grid">
                {devotions.map((d) => (
                    <div key={d.name} className="constellation-card">
                        <div className="constellation-name">{d.name}</div>
                        <div className="constellation-stars muted">
                            {d.stars} {d.stars === 1 ? "star" : "stars"}
                        </div>
                        <GroupedStats {...groupBonuses([d.bonuses])} />
                    </div>
                ))}
            </div>
        </>
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
