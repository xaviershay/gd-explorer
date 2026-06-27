import { useEffect, useState } from "react";

// Minimal hash-based router: returns the current "#/path" without the leading
// "#". Hash routing avoids needing a server-side SPA fallback.
export function useHashRoute(): string {
  const get = () => window.location.hash.replace(/^#/, "") || "/sets";
  const [route, setRoute] = useState(get);
  useEffect(() => {
    const onChange = () => setRoute(get());
    window.addEventListener("hashchange", onChange);
    return () => window.removeEventListener("hashchange", onChange);
  }, []);
  return route;
}

type AsyncState<T> =
  | { status: "loading" }
  | { status: "error"; error: string }
  | { status: "ok"; data: T };

// Fetch helper that re-runs when a dependency key changes.
export function useAsync<T>(fn: () => Promise<T>, key: string): AsyncState<T> {
  const [state, setState] = useState<AsyncState<T>>({ status: "loading" });
  useEffect(() => {
    let alive = true;
    setState({ status: "loading" });
    fn()
      .then((data) => alive && setState({ status: "ok", data }))
      .catch((e) => alive && setState({ status: "error", error: String(e) }));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

// Like useAsync, but keeps the previous data visible while a new key loads
// (so live recomputes don't blank the screen). `loading` flags the refetch.
export function useAsyncKeep<T>(
  fn: () => Promise<T>,
  key: string,
): { data?: T; loading: boolean; error?: string } {
  const [data, setData] = useState<T>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError(undefined);
    fn()
      .then((d) => alive && (setData(d), setLoading(false)))
      .catch((e) => alive && (setError(String(e)), setLoading(false)));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return { data, loading, error };
}
