import { useEffect, useState } from "react";
import { SkillInfo } from "./api";

// Skill display name -> tooltip info (description + what it grants), served by
// /api/skills. Used for hover cards on "Grants X" and "+N (to) X" bonus lines.
// Fetched once and cached module-wide.
export type SkillDict = Record<string, SkillInfo>;

let cache: SkillDict | null = null;
let inflight: Promise<SkillDict> | null = null;

function load(): Promise<SkillDict> {
  if (cache) return Promise.resolve(cache);
  if (!inflight) {
    inflight = fetch("/api/skills")
      .then((r) => (r.ok ? r.json() : {}))
      .then((d: SkillDict) => {
        cache = d;
        return d;
      })
      .catch(() => ({}) as SkillDict);
  }
  return inflight;
}

export function useSkillDict(): SkillDict {
  const [dict, setDict] = useState<SkillDict>(cache ?? {});
  useEffect(() => {
    let alive = true;
    load().then((d) => alive && setDict(d));
    return () => {
      alive = false;
    };
  }, []);
  return dict;
}

// The skill a bonus line refers to, or null when it isn't a single named skill
// (e.g. "+3 to all Skills"). Only meaningful for lines already known to be skill
// bonuses (the "skills" group), so plain stat lines never reach here.
export function skillNameOf(line: string): string | null {
  let m = line.match(/^Grants\s+(.+?)\s*$/i);
  if (m) return m[1];
  m = line.match(/^[+-]?\s*[\d.]+%?\s+to\s+(.+?)\s*$/i);
  if (m) return /^all\b/i.test(m[1]) ? null : m[1];
  m = line.match(/^[+-]?\s*[\d.]+%?\s+(.+?)\s*$/);
  if (m) return /^(to|all)\b/i.test(m[1]) ? null : m[1];
  return null;
}

export function skillInfoFor(
  line: string,
  dict: SkillDict,
): SkillInfo | undefined {
  const n = skillNameOf(line);
  return n ? dict[n] : undefined;
}
