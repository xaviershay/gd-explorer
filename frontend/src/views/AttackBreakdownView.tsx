export function AttackBreakdownView({
    name,
    attackKey,
}: {
    name: string;
    attackKey: string;
}) {
    return (
        <p className="muted">
            Loading breakdown for {name} / {attackKey}…
        </p>
    );
}
