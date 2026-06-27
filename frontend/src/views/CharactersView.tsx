import { getCharacters } from "../api";
import { useAsync } from "../hooks";

export function CharactersView() {
  const state = useAsync(getCharacters, "characters");
  if (state.status === "loading") return <p className="muted">Loading characters…</p>;
  if (state.status === "error") return <p className="error">{state.error}</p>;

  const chars = [...state.data].sort((a, b) => b.level - a.level);

  return (
    <>
      <h1>Characters ({chars.length})</h1>
      <div className="card-grid">
        {chars.map((c) => (
          <a key={c.name} className="card" href={`#/characters/${encodeURIComponent(c.name)}`}>
            <h3>
              {c.name}
              {c.hardcore && <span className="badge">Hardcore</span>}
            </h3>
            <div className="muted">
              Level {c.level} {c.className}
            </div>
            <div className="muted">
              {c.equippedCount} equipped · {c.equippedSetPieces} set pieces
            </div>
          </a>
        ))}
      </div>
    </>
  );
}
