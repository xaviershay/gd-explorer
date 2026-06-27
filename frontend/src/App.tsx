import { useHashRoute } from "./hooks";
import { SetsView } from "./views/SetsView";
import { CharactersView } from "./views/CharactersView";
import { CharacterDetailView } from "./views/CharacterDetailView";

export function App() {
  const route = useHashRoute();
  return (
    <>
      <nav>
        <span className="brand">gd-explorer</span>
        <a href="#/sets">Sets</a>
        <a href="#/characters">Characters</a>
      </nav>
      <main>{renderRoute(route)}</main>
    </>
  );
}

function renderRoute(route: string) {
  const charMatch = route.match(/^\/characters\/(.+)$/);
  if (charMatch) {
    return <CharacterDetailView name={decodeURIComponent(charMatch[1])} />;
  }
  if (route.startsWith("/characters")) return <CharactersView />;
  return <SetsView />;
}
