// An attack/proc row's identity, as used both by the URL route
// (#/characters/:name/attacks/:key) and by the /attack-breakdown API query
// (kind/attack/rank params). Neither kind, name, nor rank alone is a stable
// key (e.g. two different procs can share a display name), so the three are
// joined with ":" and the whole thing URL-encoded — encoding first means any
// literal ":" in a skill's display name survives the round trip.
export function encodeAttackKey(
    kind: "active" | "proc",
    name: string,
    rank: number | null,
): string {
    return encodeURIComponent(`${kind}:${name}:${rank ?? ""}`);
}

export function decodeAttackKey(
    key: string,
): { kind: "active" | "proc"; name: string; rank: number | null } {
    const [kind, name, rankStr] = decodeURIComponent(key).split(":");
    return {
        kind: kind === "proc" ? "proc" : "active",
        name,
        rank: rankStr ? Number(rankStr) : null,
    };
}
