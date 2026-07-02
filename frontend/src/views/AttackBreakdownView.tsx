import { getAttackBreakdown, SourceCategory, SourceImpact } from "../api";
import { useAsync } from "../hooks";
import { loadConfig } from "./CharacterDetailView";
import { decodeAttackKey } from "../attackKey";

const num = (n: number) => Math.round(n).toLocaleString();

// Human label + a fixed colour per source category, shared by every table on
// this page (impact ranking, flat/percent contributors, rate factors).
const CATEGORY_LABEL: Record<SourceCategory, string> = {
    gear: "Gear",
    component: "Component",
    augment: "Augment",
    setBonus: "Set Bonus",
    devotion: "Devotion",
    mastery: "Mastery",
    skill: "Skill",
    retaliation: "Retaliation",
    other: "Other",
};

const CATEGORY_COLOR: Record<SourceCategory, string> = {
    gear: "#5a9bff",
    component: "#4caf50",
    augment: "#d4c84a",
    setBonus: "#b56cff",
    devotion: "#ff8a3a",
    mastery: "#ff5a7a",
    skill: "#43d1c9",
    retaliation: "#c9c9c9",
    other: "#9a9a9a",
};

export function CategoryBadge({ category }: { category: SourceCategory }) {
    return (
        <span
            className="category-badge"
            style={{ color: CATEGORY_COLOR[category] }}
        >
            {CATEGORY_LABEL[category]}
        </span>
    );
}

export function AttackBreakdownView({
    name,
    attackKey,
}: {
    name: string;
    attackKey: string;
}) {
    const { kind, name: attackName, rank } = decodeAttackKey(attackKey);
    const cfg = loadConfig(name);
    const overrides = cfg?.overrides ?? {};
    const difficulty = cfg?.difficulty ?? "ultimate";

    const state = useAsync(
        () =>
            getAttackBreakdown(
                name,
                kind,
                attackName,
                rank,
                overrides,
                difficulty,
            ),
        `attack-breakdown:${name}:${attackKey}:${difficulty}:${JSON.stringify(overrides)}`,
    );

    const backHref = `#/characters/${encodeURIComponent(name)}`;

    if (state.status === "error") return <p className="error">{state.error}</p>;
    if (state.status === "loading")
        return <p className="muted">Loading breakdown…</p>;
    if (!state.data)
        return (
            <>
                <p className="error">
                    No matching attack/proc row found — it may no longer
                    apply under the current gear configuration.
                </p>
                <a href={backHref}>&larr; Back to {name}</a>
            </>
        );

    const bd = state.data;

    return (
        <div className="breakdown-page">
            <a className="breakdown-back" href={backHref}>
                &larr; Back to {name}
            </a>
            <h1 className="breakdown-title">
                {bd.name}
                {bd.rank != null && <span className="muted"> ({bd.rank})</span>}
                <span className="muted">
                    {" "}
                    — {bd.kind === "proc" ? "proc" : "attack"}
                </span>
            </h1>
            <div className="breakdown-summary">
                <span className="breakdown-dps">
                    {num(bd.dps)} <span className="muted">dps</span>
                </span>
                <span className="muted">
                    per-hit {num(bd.perHit)} · {bd.rate}
                </span>
            </div>

            <ImpactSection sources={bd.sourcesByImpact} />
        </div>
    );
}

function ImpactSection({ sources }: { sources: SourceImpact[] }) {
    if (sources.length === 0) return null;
    return (
        <>
            <h2 className="section-head">Sources ranked by DPS impact</h2>
            <p className="muted">
                Each row is an independent counterfactual — this attack's DPS
                with vs. without that one source, holding everything else
                fixed. Rows won't necessarily sum to the total above:
                overlapping percentage bonuses each show their full
                individual impact.
            </p>
            <table className="contrib-table impact-table">
                <thead>
                    <tr>
                        <th>Source</th>
                        <th>Category</th>
                        <th className="num-col">DPS impact</th>
                    </tr>
                </thead>
                <tbody>
                    {sources.map((s, i) => (
                        <tr key={i}>
                            <td>{s.label}</td>
                            <td>
                                <CategoryBadge category={s.category} />
                            </td>
                            <td className="num-col">
                                {s.dpsImpact >= 0 ? "+" : ""}
                                {num(s.dpsImpact)}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </>
    );
}
