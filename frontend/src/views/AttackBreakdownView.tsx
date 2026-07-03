import {
    getAttackBreakdown,
    RateFactor,
    RetaliationBreakdown,
    RetaliationTypeBreakdown,
    SourceCategory,
    SourceContribution,
    SourceImpact,
    Trigger,
    TypeBreakdown,
} from "../api";
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

            {bd.types.map((t, i) => (
                <TypeSection key={i} t={t} />
            ))}

            {bd.retaliation && <RetaliationSection r={bd.retaliation} />}

            {bd.rateFactors.length > 0 && (
                <>
                    <h2 className="section-head">Rate</h2>
                    {bd.rateFactors.map((rf, i) => (
                        <RateFactorBlock key={i} rf={rf} />
                    ))}
                </>
            )}
            {bd.trigger && <TriggerBlock trigger={bd.trigger} />}
        </div>
    );
}

// A horizontal bar showing |value| relative to |max| (the largest magnitude
// in the same table), so bars are only ever compared within one table.
function MagnitudeBar({ value, max }: { value: number; max: number }) {
    const pct = max > 0 ? Math.min(100, (Math.abs(value) / max) * 100) : 0;
    return (
        <div className="magnitude-bar-track">
            <div className="magnitude-bar-fill" style={{ width: `${pct}%` }} />
        </div>
    );
}

function ImpactSection({ sources }: { sources: SourceImpact[] }) {
    if (sources.length === 0) return null;
    // already sorted by |impact| descending (see attackDpsBreakdown), so the
    // first row is the max magnitude for the bar scale.
    const max = Math.abs(sources[0].dpsImpact);
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
                        <th className="bar-col"></th>
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
                            <td className="bar-col">
                                <MagnitudeBar value={s.dpsImpact} max={max} />
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </>
    );
}

function ContribTable({
    rows,
    valueLabel,
    total,
}: {
    rows: SourceContribution[];
    valueLabel: string;
    total: number;
}) {
    if (rows.length === 0) return null;
    const sorted = [...rows].sort(
        (a, b) => Math.abs(b.value) - Math.abs(a.value),
    );
    const max = Math.abs(sorted[0].value);
    return (
        <table className="contrib-table">
            <thead>
                <tr>
                    <th>Source</th>
                    <th>Category</th>
                    <th className="num-col">{valueLabel}</th>
                    <th className="bar-col"></th>
                </tr>
            </thead>
            <tbody>
                {sorted.map((r, i) => (
                    <tr key={i}>
                        <td>{r.label}</td>
                        <td>
                            <CategoryBadge category={r.category} />
                        </td>
                        <td className="num-col">{num(r.value)}</td>
                        <td className="bar-col">
                            <MagnitudeBar value={r.value} max={max} />
                        </td>
                    </tr>
                ))}
            </tbody>
            <tfoot>
                <tr>
                    <td colSpan={2}>Total</td>
                    <td className="num-col">{num(total)}</td>
                    <td className="bar-col" />
                </tr>
            </tfoot>
        </table>
    );
}

function TypeSection({ t }: { t: TypeBreakdown }) {
    const isDot = t.label.endsWith("(dot)");
    return (
        <>
            <h2 className="section-head">
                {t.label}
                <span className="muted"> — {num(t.total)} per hit</span>
            </h2>
            <div className="breakdown-columns">
                <div>
                    <div className="breakdown-col-head">Flat damage</div>
                    <ContribTable
                        rows={t.flat}
                        valueLabel="Flat"
                        total={t.flatSubtotal}
                    />
                </div>
                {!isDot && t.percent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">% increase</div>
                        <ContribTable
                            rows={t.percent}
                            valueLabel="%"
                            total={t.totalPercent}
                        />
                    </div>
                )}
                {isDot && t.durationPercent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">Duration %</div>
                        <ContribTable
                            rows={t.durationPercent}
                            valueLabel="%"
                            total={t.totalDurationPercent}
                        />
                    </div>
                )}
                {isDot && t.damagePercent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">Damage %</div>
                        <ContribTable
                            rows={t.damagePercent}
                            valueLabel="%"
                            total={t.totalDamagePercent}
                        />
                    </div>
                )}
            </div>
            {isDot && (
                <p className="muted breakdown-formula">
                    {num(t.flatSubtotal)} x (1 + {num(t.totalDurationPercent)}
                    %) x (1 + {num(t.totalDamagePercent)}%) = {num(t.total)}
                </p>
            )}
        </>
    );
}

function RetaliationSection({ r }: { r: RetaliationBreakdown }) {
    return (
        <>
            <h2 className="section-head">Retaliation added to attack</h2>
            <div className="breakdown-col-head">
                % of retaliation damage added to attack
            </div>
            <ContribTable
                rows={r.addToAttackPct}
                valueLabel="%"
                total={r.totalAddToAttackPct}
            />
            {r.byType.map((t, i) => (
                <RetaliationTypeBlock key={i} t={t} />
            ))}
        </>
    );
}

function RetaliationTypeBlock({ t }: { t: RetaliationTypeBreakdown }) {
    return (
        <div className="retaliation-type-block">
            <h3 className="breakdown-subhead">{t.label}</h3>
            <div className="breakdown-columns">
                <div>
                    <div className="breakdown-col-head">Flat retaliation</div>
                    <ContribTable
                        rows={t.flat}
                        valueLabel="Flat"
                        total={t.flatSubtotal}
                    />
                </div>
                {t.percent.length > 0 && (
                    <div>
                        <div className="breakdown-col-head">% modifiers</div>
                        <ContribTable
                            rows={t.percent}
                            valueLabel="%"
                            total={t.totalPercent}
                        />
                    </div>
                )}
            </div>
            <p className="muted breakdown-formula">
                {num(t.flatSubtotal)} x (1 + {num(t.totalPercent)}%) ={" "}
                {num(t.retaliationDamage)} retaliation damage &rarr;{" "}
                {num(t.addedToAttack)} added to this attack
            </p>
        </div>
    );
}

function RateFactorBlock({ rf }: { rf: RateFactor }) {
    return (
        <div className="retaliation-type-block">
            <h3 className="breakdown-subhead">{rf.label}</h3>
            <ContribTable
                rows={rf.contributions}
                valueLabel="%"
                total={rf.contributions.reduce((s, c) => s + c.value, 0)}
            />
            <p className="muted breakdown-formula">{rf.formula}</p>
        </div>
    );
}

function TriggerBlock({ trigger }: { trigger: Trigger }) {
    return (
        <>
            <h2 className="section-head">Trigger</h2>
            <p className="muted">
                {num(trigger.chancePct)}% chance on attack,{" "}
                {num(trigger.cooldown)}s cooldown — granted by{" "}
                {trigger.grantedBy}.
            </p>
        </>
    );
}
