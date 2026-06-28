import { useEffect, useRef, useState } from "react";
import { Enhancement, RankEntry } from "../api";
import { rarityColor } from "../colors";
import {
    Element,
    ELEMENT_COLOR,
    ElementIcon,
    elementColor,
    elementOf,
} from "../elements";
import { ItemImage } from "./ItemImage";

// Element filter chips, in the usual resistance order.
const FILTER_ELEMENTS: Element[] = [
    "fire",
    "cold",
    "lightning",
    "acid",
    "vitality",
    "aether",
    "chaos",
    "bleeding",
    "pierce",
    "physical",
];

const linesOf = (e: Enhancement) => [
    ...e.resistBonuses,
    ...e.damageBonuses,
    ...e.bonuses,
    ...e.skillBonuses,
];

// Stat lines grouped and labelled by category, so it's obvious at a glance
// which numbers are resistances, damage, etc. — the underlying data already
// arrives split, we just render each group with a small leading tag.
const STAT_GROUPS: { key: keyof Enhancement; label: string }[] = [
    { key: "resistBonuses", label: "RES" },
    { key: "damageBonuses", label: "DMG" },
    { key: "bonuses", label: "STAT" },
    { key: "skillBonuses", label: "SKILL" },
];

function GroupedLines({ e }: { e: Enhancement }) {
    return (
        <>
            {STAT_GROUPS.map(({ key, label }) => {
                const lines = e[key] as string[];
                if (lines.length === 0) return null;
                return (
                    <div key={key} className="enh-group">
                        <span className="enh-group-label muted">{label}</span>
                        {lines.map((l, i) => (
                            <span
                                key={i}
                                className="dtype"
                                style={{ color: elementColor(l) }}
                            >
                                {l}
                            </span>
                        ))}
                    </div>
                );
            })}
        </>
    );
}

// Filter by free text (name or any stat line) and by required elements (a stat
// must mention one of the selected damage/resistance types).
function matches(e: Enhancement, query: string, elems: Set<Element>): boolean {
    const lines = linesOf(e);
    if (
        query &&
        !(
            e.name.toLowerCase().includes(query) ||
            lines.some((l) => l.toLowerCase().includes(query))
        )
    )
        return false;
    if (
        elems.size > 0 &&
        !lines.some((l) => {
            const el = elementOf(l);
            return el !== null && elems.has(el);
        })
    )
        return false;
    return true;
}

// Reorder @items@ by their position in @order@ (a record list, best-first).
// Items missing from @order@ are appended in their original order.
function sortByRanking(
    items: Enhancement[],
    order: RankEntry[],
): Enhancement[] {
    const rank = new Map<string, number>();
    order.forEach((r, i) => rank.set(r.record, i));
    const known = items.filter((o) => rank.has(o.record));
    const unknown = items.filter((o) => !rank.has(o.record));
    known.sort((a, b) => rank.get(a.record)! - rank.get(b.record)!);
    return [...known, ...unknown];
}

// A searchable component/augment picker: a trigger showing the current choice,
// opening a popover with a name/stat search box, element filter chips, and the
// matching options (icon + name + stats). Replaces a plain <select>.
//
// When @fetchRanking@ is supplied, options are reordered by the returned
// best-first record list as soon as the popover opens (cached for subsequent
// opens; cleared when the closure identity changes, e.g. on override change).
export function EnhancementPicker({
    label,
    current,
    options,
    onChange,
    fetchRanking,
}: {
    label: string;
    current: string | null;
    options: Enhancement[];
    onChange: (record: string) => void;
    fetchRanking?: () => Promise<RankEntry[]>;
}) {
    const [open, setOpen] = useState(false);
    const [query, setQuery] = useState("");
    const [elems, setElems] = useState<Set<Element>>(new Set());
    const [ranking, setRanking] = useState<RankEntry[] | null>(null);
    const [loading, setLoading] = useState(false);
    const ref = useRef<HTMLDivElement>(null);

    // Drop any cached ranking when the fetcher's identity changes (e.g. when the
    // character's overrides changed and rankings would now be stale).
    useEffect(() => {
        setRanking(null);
    }, [fetchRanking]);

    // Fetch the per-slot ranking the first time the popover is opened.
    useEffect(() => {
        if (!open || ranking || !fetchRanking) return;
        let cancelled = false;
        setLoading(true);
        fetchRanking()
            .then((r) => {
                if (!cancelled) setRanking(r);
            })
            .catch(() => {
                /* leave unsorted on failure */
            })
            .finally(() => {
                if (!cancelled) setLoading(false);
            });
        return () => {
            cancelled = true;
        };
    }, [open, ranking, fetchRanking]);

    useEffect(() => {
        if (!open) return;
        const onDown = (e: MouseEvent) => {
            if (ref.current && !ref.current.contains(e.target as Node))
                setOpen(false);
        };
        const onKey = (e: KeyboardEvent) =>
            e.key === "Escape" && setOpen(false);
        document.addEventListener("mousedown", onDown);
        document.addEventListener("keydown", onKey);
        return () => {
            document.removeEventListener("mousedown", onDown);
            document.removeEventListener("keydown", onKey);
        };
    }, [open]);

    const sel = options.find((o) => o.record === current);
    const q = query.trim().toLowerCase();
    const filtered = options.filter((o) => matches(o, q, elems));
    // When fetchRanking is provided, only show items that are in the ranked
    // results (which are already filtered for buyability on the server). While
    // loading, show nothing so unbuyable items never flash up.
    const scoreOf = ranking
        ? new Map(ranking.map((r) => [r.record, r.score]))
        : null;
    const ranked = ranking
        ? sortByRanking(filtered, ranking).filter((o) => scoreOf!.has(o.record))
        : fetchRanking
          ? []
          : filtered;

    const choose = (record: string) => {
        onChange(record);
        setOpen(false);
        setQuery("");
        setElems(new Set());
    };
    const toggle = (el: Element) =>
        setElems((s) => {
            const n = new Set(s);
            n.has(el) ? n.delete(el) : n.add(el);
            return n;
        });

    return (
        <div className="enh-picker" ref={ref}>
            <div className="enh-triggerline">
                <button
                    className="enh-trigger"
                    onClick={() => setOpen((o) => !o)}
                    title={sel ? sel.name : `No ${label.toLowerCase()}`}
                >
                    {current && <ItemImage record={current} />}
                    <span className="enh-trigger-label muted">{label}</span>
                    <span
                        className="enh-trigger-name"
                        style={
                            sel
                                ? { color: rarityColor(sel.classification) }
                                : undefined
                        }
                    >
                        {sel ? sel.name : `— None —`}
                    </span>
                    <span className="enh-caret muted">▾</span>
                </button>
                {current && (
                    <button
                        className="enh-remove"
                        title={`Remove ${label.toLowerCase()}`}
                        onClick={() => onChange("none")}
                    >
                        ×
                    </button>
                )}
            </div>

            {sel && (
                <div className="enh-stats">
                    <GroupedLines e={sel} />
                </div>
            )}

            {open && (
                <div className="enh-pop">
                    <input
                        className="enh-search"
                        autoFocus
                        placeholder={`Search ${label.toLowerCase()} or stat…`}
                        value={query}
                        onChange={(e) => setQuery(e.target.value)}
                    />
                    <div className="enh-chips">
                        {FILTER_ELEMENTS.map((el) => (
                            <button
                                key={el}
                                className={
                                    "enh-chip" + (elems.has(el) ? " on" : "")
                                }
                                style={{ color: ELEMENT_COLOR[el] }}
                                title={el}
                                onClick={() => toggle(el)}
                            >
                                <ElementIcon element={el} size={16} />
                            </button>
                        ))}
                    </div>
                    <ul className="enh-options">
                        <li
                            className="enh-option none"
                            onClick={() => choose("none")}
                        >
                            — No {label} —
                        </li>
                        {loading && (
                            <li className="enh-option muted">
                                Scoring alternatives…
                            </li>
                        )}
                        {ranked.map((o) => (
                            <li
                                key={o.record}
                                className={
                                    "enh-option" +
                                    (o.record === current ? " selected" : "")
                                }
                                onClick={() => choose(o.record)}
                            >
                                <ItemImage record={o.record} />
                                <div className="enh-option-body">
                                    <div className="enh-option-head">
                                        <span
                                            className="enh-option-name"
                                            style={{
                                                color: rarityColor(
                                                    o.classification,
                                                ),
                                            }}
                                        >
                                            {o.name}
                                        </span>
                                        {scoreOf && scoreOf.has(o.record) && (
                                            <span
                                                className="enh-score"
                                                title="upgrade score (higher is better)"
                                            >
                                                {scoreOf.get(o.record)! > 0
                                                    ? "+"
                                                    : ""}
                                                {Math.round(
                                                    scoreOf.get(o.record)!,
                                                ).toLocaleString()}
                                            </span>
                                        )}
                                    </div>
                                    <div className="enh-option-stats">
                                        <GroupedLines e={o} />
                                    </div>
                                </div>
                            </li>
                        ))}
                        {!loading && ranked.length === 0 && (
                            <li className="enh-option muted">No matches</li>
                        )}
                    </ul>
                </div>
            )}
        </div>
    );
}
