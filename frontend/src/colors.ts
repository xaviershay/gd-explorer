// Rarity palette, mirroring src/GrimDawn/Report/Color.hs:
// Magical=yellow, Rare=green, Epic=blue, Legendary=purple, Common=default.
export function rarityColor(classification: string | null): string {
  switch ((classification ?? "").toLowerCase()) {
    case "magical":
      return "#d4c84a";
    case "rare":
      return "#4caf50";
    case "epic":
      return "#5a9bff";
    case "legendary":
      return "#b56cff";
    default:
      return "#c9c9c9";
  }
}

// Heatmap colour for a set-completion ratio (0..1): red -> amber -> green.
export function completionColor(owned: number, total: number): string {
  if (total === 0) return "#333";
  const r = owned / total;
  const hue = Math.round(r * 120); // 0 = red, 120 = green
  return `hsl(${hue}, 55%, ${22 + Math.round(r * 12)}%)`;
}
