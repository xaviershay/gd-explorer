# gd-explorer — agent guide

A tool for exploring Grim Dawn save data + game database: a Haskell library/CLI
that parses the game's `.arz`/`.arc`/`.gdc` files, plus a local web UI (Haskell
HTTP server + React frontend) for browsing sets, characters, gear, DPS, and a
component/augment "what-if" configurator.

## Build & run

Build tool is **stack** (GHC 9.10, LTS 24.45).

> **Critical environment quirk:** this machine has no `libgmp.so` dev symlink on
> the default linker path, so builds fail with `cannot find -lgmp` unless you
> point stack at linuxbrew's copy. **Always** pass:
>
> ```
> stack build --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib
> stack test  --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib
> ```
>
> The user normally builds in an interactive shell where linuxbrew is on the
> path, so they may not hit this.

Run the web server (loads the game DB once, ~seconds, then serves):

```
BIN=$(stack path --local-install-root --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib)/bin/gd-explorer
LD_LIBRARY_PATH=/var/home/linuxbrew/.linuxbrew/lib "$BIN" serve --port 8080
```

Background server processes started from the Bash tool with a trailing `&`/`exec`
do **not** persist reliably; use the tool's `run_in_background: true` instead.
They report `failed` on cleanup `pkill` — that's expected, not an error.

Frontend (React + Vite, in `frontend/`): `npm --prefix frontend run build`
(runs `tsc --noEmit` then `vite build` into `frontend/dist`, which the server
serves statically and picks up from disk live).

CLI commands: `gd-explorer {sets|items|character|dps|upgrades} ...`
(see `src/GrimDawn/Cli.hs`). The web server is the `serve` subcommand.

## Data location

Game data lives under `data/gd-data/game/` (`database/*.arz`, `resources/*.arc`,
gdx1/gdx2 variants); saves under `data/gd-data/save/`. Sync scripts:
`scripts/fetch-gd-data.sh`, `scripts/sync-data.sh` (these pull `Text_EN.arc` AND
`Items.arc` — the latter is needed for item icons).

## Architecture / where things live

- `src/GrimDawn/` — the core library:
  - `Arc.hs` (`.arc` reader, incl. binary asset extraction), `Arz.hs`, `Gdc.hs`
    (save/character parser), `Db.hs` (merged record DB + localization), `Item.hs`
    (item attribute rendering, `relatedRecords`, `iaBitmap`, `sumField`/`sumRange`),
    `Lz4.hs` + `cbits/lz4_shim.c` (vendored LZ4 block decoder).
  - `Report/Stats.hs` — **the stat & DPS engine** (resistances, key totals,
    `attackDps`, conversions, retaliation). Large and important.
  - `Report/Sets.hs`, `Report/Character.hs`, `Report/Items.hs` — CLI reports.
  - `Web/View.hs` — JSON view models for the web API (lives in the *main* lib).
- `src-web/GrimDawn/Web/` — the `web` internal library:
  - `Server.hs` (scotty/warp routes), `Texture.hs` (`.tex` → PNG decoder).
- `app/Main.hs` — CLI entry; `serve` dispatches to `Web/Server.runServer`.
- `frontend/src/` — React app (hash-routed). Key files:
  - `api.ts` (types + fetchers), `hooks.ts` (`useAsync`, `useAsyncKeep`),
    `elements.tsx` (element colors/icons, `ResistRow`, `orderedResists`),
    `bonuses.tsx` (`groupBonuses` + `GroupedStats`: resist icons + Skills/Stats/
    Combat/Other grouping — shared by sets & character views),
    `components/ItemImage.tsx`, `components/ItemAttributes.tsx`,
    `components/EnhancementPicker.tsx` (searchable component/augment picker),
    `views/SetsView.tsx`, `views/CharacterDetailView.tsx`.

## Web API (served by `Server.hs`)

- `GET /api/sets` — set completion + members.
- `GET /api/characters` — character summaries.
- `GET /api/characters/:name` — full detail: stat summary (resists w/ caps,
  attributes, key totals, total damage bonuses), attack DPS rows, gear, and a
  **shopping list**. Accepts per-slot override query params
  `comp.<i>=<record|none>` / `aug.<i>=<record|none>` (i = index into the gear
  list) and recomputes everything with that component/augment substituted.
- `GET /api/enhancements` — catalog of all components + augments (name, level,
  slots, stats) for the configurator; frontend filters per slot/level.
- `GET /api/item-image/:record` — item icon as PNG (decoded from `.tex`).

## Web UI features (character detail page)

- Sticky compact summary (resist icons + damage bonuses) pinned while scrolling.
- Stat summary panel (resists at Ultimate, attributes, OA/DA/Armor/Health/Energy).
- Attack DPS estimate (active "pick one" attacks; WPS + procs additive).
- Equipment paper-doll grid: top row ring·head·amulet·ring; two mid columns
  (LHS weapon·chest·legs, RHS shield/weapon2·shoulders·hands·feet); bottom row
  relic·waist·medal. Each card shows grouped stats + component/augment pickers.
- Per-slot component & augment **selectors** (searchable popover, element filter
  chips, ✕ to remove) that recompute the whole sheet live. Global "Max level"
  caps the offered enhancements. "Reset configuration" clears overrides.
- Shopping list: components/augments in the current config not on the saved
  character, with faction-vendor hints for augments.

## Grim Dawn domain knowledge (non-obvious, learned the hard way)

- **Acid damage is stored under the internal stem `Poison`** (`offensivePoison*`);
  the over-time "Poison" DoT is `offensiveSlowPoison*`. So "Acid" in the UI ==
  stem `Poison` in the data. Likewise resist field stems differ from display
  (see `resistFieldMap`, `resistStem`/`resistToken`).
- **Components** = records with `Class=ItemRelic` (under `records/items/materia/`),
  attached to gear via `itemRelicName`; icon in `relicBitmap`; name in the
  `description` field (not `itemNameTag`). **Augments** = `Class=ItemEnchantment`
  (`records/items/enchants/…`), attached via `itemAugmentName`; icon in `bitmap`.
  Both are part of `relatedRecords`, so they already flow through the stat engine.
- **Slot compatibility** for components/augments is **boolean flag fields** on the
  record named by slot: `head`, `shoulders`, `chest`, `hands`, `legs`, `feet`,
  `waist`, `amulet`, `medal`, `ring`, `offhand`, `shield`, and weapon types
  (`sword`/`sword2h`/`axe`/`axe2h`/`mace`/`mace2h`/`dagger`/`scepter`/`spear2h`/
  `ranged1h`/`ranged2h`). A gear item's `type` maps onto these directly.
- **`.tex` files** wrap a DDS behind a 12-byte header (`"TEX\2"`, zero word,
  payload length); the embedded DDS magic's 4th byte is `R` not space. GD leaves
  the DDS channel masks zeroed → assume A8R8G8B8/R8G8B8 (B,G,R[,A]). Formats used
  in `Items.arc`: DXT1/DXT3/DXT5 + uncompressed RGB24/RGB32. Relics store their
  icon in `artifactBitmap`, components in `relicBitmap` (see `iaBitmap` fallback).
- **`Items.arc` keys omit the leading `items/`** that records reference (record
  bitmap `items/gearhead/…` → archive key `gearhead/…`); see `textureKey`.
- **Augment faction vendor** = the `factionSource` field. There is **no enum→name
  mapping in the game data**; it was derived from the unambiguous faction-named
  augments each `UserN` sells. Confirmed/used mapping (in `View.factionName`):
  User0=Rovers, User2=Black Legion, User4=The Outcast, User5=Order of Death's
  Vigil, User7=Devil's Crossing, User8=Kymon's Chosen, User9=Coven of Ugdenbog,
  User10=Barrowholm, User11=Malmouth Resistance, User13=Cult of Bysmiel,
  User14=Cult of Dreeg, User15=Cult of Solael; readable values (e.g. Forgotten
  Gods "Survivors") pass through; unknown `UserN` → no source. Components have no
  vendor in the data (crafted/found).

## DPS engine notes (`Report/Stats.hs`)

- `attackDps` builds the effective `sources` = gear + devotions + mastery + skill
  buffs (the web uses **permanent** buffs and reports at **Ultimate**). It emits:
  `Active` attacks (default-attack replacers like Fire Strike/Cadence/Aegis — you
  pick one), `Triggered` WPS (have `skillChanceWeight`, e.g. Bursting Round —
  proc on attack, additive), and item/devotion/on-hit procs.
- `sumField`/`fieldNum` only read **scalar** fields (arrays return `Nothing`);
  per-rank arrays are read via `atRank`.
- **Retaliation-added-to-attack (RATA):** a % of total retaliation (incl.
  retaliation % bonuses) added as flat per-hit damage. It is added **outside** the
  skill's weapon-% multiplier (treated like a skill's own flat damage), then gets
  `% damage` (offensive) bonuses and conversions. A previous bug multiplied RATA
  by weapon % too, inflating retaliation-Aegis builds ~3–5× (e.g. Shield char's
  Aegis 517k→160k). Don't reintroduce that.
- The estimate excludes crit and enemy resistance, and assumes full permanent-buff
  uptime + base attack speed — so it's an optimistic upper bound vs real testing.

## Testing

`stack test --extra-lib-dirs=/var/home/linuxbrew/.linuxbrew/lib` (hspec, 107
examples). Data-dependent specs skip gracefully when `data/gd-data` is absent.
Frontend has no test suite; rely on `npm --prefix frontend run build` (typechecks)
and screenshotting via headless chromium (`chromium-browser --headless
--screenshot=… "http://localhost:PORT/#/…"`) — note `autoFocus` can scroll the
capture; inspect the DOM with `--dump-dom` to verify rendering.

## State / caveats

- Everything in this session is **uncommitted** (working tree). New files:
  `frontend/src/bonuses.tsx`, `frontend/src/components/EnhancementPicker.tsx`.
- Faction hints for augments are best-effort (data has no authoritative mapping).
- The configurator doesn't enforce augment faction-reputation requirements; it
  filters only by slot + level.
