# gd-explorer

A read-only Haskell library + CLI for exploring [Grim Dawn](https://www.grimdawn.com/)
save data. It parses the game database (`.arz`), localization (`.arc`), your
characters (`.gdc`), and the shared transfer stash (`.gst`) to answer two
questions across **all** your characters and the shared stash:

1. **Set completion** — which set items you own and which you're missing.
2. **Filterable inventory** — list items filtered by resistance, damage type,
   item slot, set membership, character, and level.

It never writes save files.

## Data layout

Point `--data-dir` at a directory holding `game/` and `save/` (default
`data/gd-data`):

```
data/gd-data/
  game/
    database/database.arz        # base game DB
    resources/Text_EN.arc        # base English text
    gdx1/database/GDX1.arz        gdx1/resources/Text_EN.arc   # Ashes of Malmouth
    gdx2/database/GDX2.arz        gdx2/resources/Text_EN.arc   # Forgotten Gods
    gdx3/database/GDX3.arz        gdx3/resources/Text_EN.arc   # Fangs of Asterkarn (optional)
  save/
    transfer.gst                 # shared/transfer stash
    main/<CharacterName>/player.gdc
```

DLC tiers are optional — whatever is present is loaded and merged, with later
DLCs overriding earlier ones. The `scripts/fetch-gd-data.sh` helper can stage
this subset from a Windows install (run under WSL).

## Build & test

```sh
stack build
stack test          # data-dependent tests skip gracefully if data/ is absent
```

## Usage

```sh
stack run -- <command> [options]
# or run the built binary directly:
gd-explorer <command> [options]
```

### `sets` — set completion

Shows only sets you own at least one piece of, listing each piece with how many
you have and where they are:

```sh
gd-explorer sets
```

```
Absolution  2/5
    Faceguard of Perdition  missing
    Chestguard of Perdition  x2  (shared stash x2)
    Handguards of Perdition  x3  (Adam (stash) x2, shared stash)
    Shoulderguards of Perdition  missing
    Shield of Perdition  missing
Adornments of Valiance  2/4
    Pendant of Valiance  x1  (Adam (stash))
    Ribbon of Valiance  missing
    Ring of Valiance  x1  (Snake Eyes (inventory))
    Signet of Valiance  missing
```

The header `2/5` counts distinct member pieces owned. By default fully-completed
sets are hidden; add `--all` to include them:

```sh
gd-explorer sets --all
gd-explorer sets --data-dir /path/to/data
```

### `items` — filterable inventory

Each filter narrows the results (they combine as AND); `--resist` and `--damage`
may be repeated. Output is a table of name, type, level, resists, damage,
location, and count.

```sh
# fire-resistant helms anywhere
gd-explorer items --type helm --resist fire

# rings with chaos resistance
gd-explorer items --type ring --resist chaos
```

```
Name                                  Type  Lvl  Resists                     Damage  Location           Cnt
------------------------------------  ----  ---  --------------------------  ------  -----------------  ---
Baldir's Mask                         head  65   chaos,cold,fire,lightning           shared stash       1
Bloodreaper's Cowl                    head  20   cold,fire,lightning                 shared stash       1
Celestial Woven Coif of the Mountain  head       chaos,cold,fire,lightning           Beats (inventory)  1
```

More examples:

```sh
# set items requiring level 60+
gd-explorer items --set --min-level 60

# everything with both fire and cold resistance
gd-explorer items --resist fire --resist cold

# weapons dealing lightning damage held by a specific character
gd-explorer items --type sword --damage lightning --char Adam

# items usable below level 25
gd-explorer items --max-level 25
```

#### `items` options

| Option | Description |
|--------|-------------|
| `--type TYPE` | Item slot/type, e.g. `helm`, `ring`, `amulet`, `sword`, `chest` (common synonyms like `helm`→head are understood) |
| `--resist RES` | Require a resistance: `fire`, `cold`, `lightning`, `poison`, `aether`, `chaos`, `vitality`, `pierce`, `bleed` (repeatable) |
| `--damage DMG` | Require an offensive damage type, same vocabulary plus `physical`/`elemental` (repeatable) |
| `--set` | Only set items |
| `--char NAME` | Restrict to a character (matched against the location label) |
| `--min-level N` / `--max-level N` | Bound the item's level requirement |
| `--data-dir DIR` | Data root (default `data/gd-data`) |

## How it works

Items are matched at the **record level**: filters test the stats defined on the
base item and affix records in the database (e.g. "has fire resistance", "is a
helm"), not the exact per-item rolled values. Tag strings resolve to English
display names via the merged localization tables.

See `PLAN.md` for the module layout and the save-file format details.
