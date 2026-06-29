import { Craftable, getComponents, getRelics } from "../api";
import { useAsync } from "../hooks";
import { rarityColor } from "../colors";
import { ItemImage } from "../components/ItemImage";
import { groupBonuses, GroupedStats } from "../bonuses";

// Min-level bands, matching the Sets page.
const BANDS: { label: string; min: number; max: number }[] = [
  { label: "Level 1–24", min: 1, max: 24 },
  { label: "Level 25–49", min: 25, max: 49 },
  { label: "Level 50–69", min: 50, max: 69 },
  { label: "Level 70–83", min: 70, max: 83 },
  { label: "Level 84–93", min: 84, max: 93 },
  { label: "Level 94+", min: 94, max: Infinity },
];

function bandLabel(level: number | null): string {
  if (level == null) return "Unknown level";
  return (
    BANDS.find((b) => level >= b.min && level <= b.max)?.label ?? "Unknown level"
  );
}

const STATUS_LABEL: Record<Craftable["status"], string> = {
  learned: "blueprint known",
  default: "always available",
  missing: "not found",
};

// Craftable = anything you can currently make (learned blueprint OR a default
// blacksmith recipe); only "missing" can't be crafted.
const isCraftable = (c: Craftable) => c.status !== "missing";

export function ComponentsView() {
  return (
    <CraftablesView
      title="Components"
      fetcher={getComponents}
      cacheKey="components"
    />
  );
}

export function RelicsView() {
  return (
    <CraftablesView title="Relics" fetcher={getRelics} cacheKey="relics" />
  );
}

function CraftablesView({
  title,
  fetcher,
  cacheKey,
}: {
  title: string;
  fetcher: () => Promise<Craftable[]>;
  cacheKey: string;
}) {
  const state = useAsync(fetcher, cacheKey);
  if (state.status === "loading")
    return <p className="muted">Loading {title.toLowerCase()}…</p>;
  if (state.status === "error") return <p className="error">{state.error}</p>;

  const items = state.data;
  const craftable = items.filter(isCraftable).length;

  // Group by level band, preserving band order; "Unknown" last.
  const order = [...BANDS.map((b) => b.label), "Unknown level"];
  const groups = new Map<string, Craftable[]>();
  for (const c of items) {
    const key = bandLabel(c.level);
    (groups.get(key) ?? groups.set(key, []).get(key)!).push(c);
  }

  return (
    <div>
      <h1>
        {title}{" "}
        <span className="muted">
          — {craftable}/{items.length} craftable
        </span>
      </h1>
      <p className="muted">
        Each box lists what the item grants. Coloured = you can craft it
        (blueprint known or a default blacksmith recipe); greyed = blueprint not
        found yet.
      </p>
      {order
        .filter((label) => groups.has(label))
        .map((label) => {
          // Craftable first, then by name, within each band.
          const band = groups
            .get(label)!
            .slice()
            .sort(
              (a, b) =>
                Number(isCraftable(b)) - Number(isCraftable(a)) ||
                a.name.localeCompare(b.name),
            );
          return (
            <section className="craft-section" key={label}>
              <h2 className="section-head">
                {label}{" "}
                <span className="muted">
                  ({band.filter(isCraftable).length}/{band.length})
                </span>
              </h2>
              <ul className="craft-grid">
                {band.map((c) => (
                  <Card key={c.record} c={c} />
                ))}
              </ul>
            </section>
          );
        })}
    </div>
  );
}

function Card({ c }: { c: Craftable }) {
  const { resists, groups } = groupBonuses([c.bonuses]);
  return (
    <li className={"craft-card status-" + c.status}>
      <div className="craft-head">
        <ItemImage record={c.record} />
        <div className="craft-title">
          <span
            className="craft-name"
            style={{ color: rarityColor(c.classification) }}
          >
            {c.name}
          </span>
          <span className="craft-meta muted">
            {c.level != null ? `Lvl ${c.level} · ` : ""}
            <span className={"craft-status " + c.status}>
              {STATUS_LABEL[c.status]}
            </span>
          </span>
        </div>
      </div>
      <GroupedStats resists={resists} groups={groups} inlineResists />
    </li>
  );
}
