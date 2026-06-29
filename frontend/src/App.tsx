import { useHashRoute } from "./hooks";
import { SetsView } from "./views/SetsView";
import { ComponentsView, RelicsView } from "./views/CraftablesView";
import { CharactersView } from "./views/CharactersView";
import { CharacterDetailView } from "./views/CharacterDetailView";

export function App() {
    const route = useHashRoute();
    return (
        <>
            <nav>
                <span className="brand">GD Explorer</span>
                <a href="#/sets">Sets</a>
                <a href="#/components">Components</a>
                <a href="#/relics">Relics</a>
                <a href="#/characters">Characters</a>
            </nav>
            <main>{renderRoute(route)}</main>
        </>
    );
}

function renderRoute(route: string) {
    const charMatch = route.match(/^\/characters\/(.+)$/);
    if (charMatch) {
        const name = decodeURIComponent(charMatch[1]);
        return <CharacterDetailView key={name} name={name} />;
    }
    if (route.startsWith("/characters")) return <CharactersView />;
    if (route.startsWith("/components")) return <ComponentsView />;
    if (route.startsWith("/relics")) return <RelicsView />;
    return <SetsView />;
}
