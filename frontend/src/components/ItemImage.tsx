import { useState } from "react";

// Item icon from the server, falling back to a "?" placeholder when the texture
// isn't available (archive not synced / not yet decodable).
export function ItemImage({ record }: { record: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) {
    return (
      <div className="pin-image" title="no image">
        ?
      </div>
    );
  }
  return (
    <img
      className="pin-image"
      src={`/api/item-image/${encodeURIComponent(record)}`}
      alt=""
      onError={() => setFailed(true)}
    />
  );
}
