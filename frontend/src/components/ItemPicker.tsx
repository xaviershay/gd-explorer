import { useEffect, useRef, useState } from "react";
import { ItemRank } from "../api";
import { rarityColor } from "../colors";
import { ItemImage } from "./ItemImage";

const num = (n: number) => Math.round(n).toLocaleString();

// A per-slot "swap item" picker. The trigger shows the equipped (or overridden)
// item; opening it fetches the owned items that would improve this slot — scored
// by the same `upgrades` path as the CLI — best-first, each with its location
// (which character/stash holds it). Picking one swaps the base item in the slot,
// keeping its component/augment. "Keep equipped" reverts to the saved item.
export function ItemPicker({
    current,
    currentName,
    currentClassification,
    maxLevel,
    fetchItems,
    onChange,
}: {
    current: string;
    currentName: string;
    currentClassification: string | null;
    maxLevel: number;
    fetchItems: () => Promise<ItemRank[]>;
    onChange: (record: string) => void;
}) {
    const [open, setOpen] = useState(false);
    const [items, setItems] = useState<ItemRank[] | null>(null);
    const [loading, setLoading] = useState(false);
    const ref = useRef<HTMLDivElement>(null);

    // Invalidate the cached ranking when the build (fetcher identity) changes.
    useEffect(() => {
        setItems(null);
    }, [fetchItems]);

    // Fetch alternatives the first time the popover opens (then cache).
    useEffect(() => {
        if (!open || items !== null) return;
        let cancelled = false;
        setLoading(true);
        fetchItems()
            .then((r) => { if (!cancelled) setItems(r); })
            .catch(() => {})
            .finally(() => { if (!cancelled) setLoading(false); });
        return () => {
            cancelled = true;
        };
    }, [open, items, fetchItems]);

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

    const withinLevel = (it: ItemRank) =>
        it.level === null || it.level <= maxLevel;

    const choose = (record: string) => {
        onChange(record);
        setOpen(false);
    };

    return (
        <div className="enh-picker" ref={ref}>
            <div className="enh-triggerline">
                <button
                    className="enh-trigger"
                    onClick={() => setOpen((o) => !o)}
                    title={currentName}
                >
                    {current && <ItemImage record={current} />}
                    <span className="enh-trigger-label muted">Item</span>
                    <span
                        className="enh-trigger-name"
                        style={{ color: rarityColor(currentClassification) }}
                    >
                        {currentName}
                    </span>
                    <span className="enh-caret muted">▾</span>
                </button>
            </div>

            {open && (
                <div className="enh-pop">
                    <ul className="enh-options">
                        <li
                            className="enh-option none"
                            onClick={() => choose("none")}
                        >
                            — Keep equipped —
                        </li>
                        {loading && (
                            <li className="enh-option muted">
                                Scoring alternatives…
                            </li>
                        )}
                        {items && !loading && items.filter(withinLevel).length === 0 && (
                            <li className="enh-option muted">
                                No owned upgrades for this slot
                            </li>
                        )}
                        {items?.filter(withinLevel).map((it) => (
                            <li
                                className="enh-option"
                                key={it.record + it.location}
                                onClick={() => choose(it.record)}
                            >
                                <ItemImage record={it.record} />
                                <div className="enh-option-body">
                                    <div className="enh-option-head">
                                        <span
                                            className="enh-option-name"
                                            style={{
                                                color: rarityColor(
                                                    it.classification,
                                                ),
                                            }}
                                        >
                                            {it.name}
                                        </span>
                                        <span
                                            className="enh-score"
                                            title="upgrade score (higher is better)"
                                        >
                                            {it.score > 0 ? "+" : ""}
                                            {num(it.score)}
                                        </span>
                                    </div>
                                    <div className="enh-option-stats">
                                        <span className="muted">
                                            {it.location}
                                            {it.level ? ` · lvl ${it.level}` : ""}
                                        </span>
                                        {(it.resistDeltas ?? []).map((d, i) => (
                                            <span key={i} className="enh-resist-delta">
                                                {d}
                                            </span>
                                        ))}
                                        {it.dpsDelta !== 0 && (
                                            <span className="muted">
                                                {it.dpsDelta > 0 ? "+" : ""}
                                                {num(it.dpsDelta)} dps
                                            </span>
                                        )}
                                    </div>
                                </div>
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </div>
    );
}
