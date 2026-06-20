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

Each filter narrows the results (they combine as AND); `--resist`, `--damage`,
and `--skill` may be repeated. Each matching item is printed as a short block: a header line
with name, **rarity**, slot, level requirement, location, and count, followed by
indented detail lines for resistances, **damage bonuses** (`+` flat and `%`
modifiers), and **skill bonuses** (only the lines that apply are shown).

When writing to a terminal, the rarity tag and the resistance / damage types are
coloured to match Grim Dawn's in-game colours (rarity: Magical yellow, Rare
green, Epic blue, Legendary purple; damage: Fire orange, Cold light blue,
Lightning yellow, Poison green, Chaos dark red, etc.); the colour is omitted when
output is piped or redirected.

```sh
# fire-resistant helms anywhere
gd-explorer items --type helm --resist fire

# rings with chaos resistance
gd-explorer items --type ring --resist chaos
```

```
Baldir's Mask [Epic] head lvl 65 — shared stash x1
    resists: chaos, cold, fire, lightning
    damage : 44% Physical
    skills : +2 Judgment, +2 Blade Arc
Champion of the Light [Epic] axe2h lvl 72 — Adam (stash) x1
    damage : +260-300 Lightning, 120% Lightning
    skills : +4 Oak Skin, +4 Counter Strike
```

Damage and skill bonuses are aggregated from the item's base and affix records.
Per the record-level approach, ranges shown reflect the database values, not the
exact per-item roll.

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

# anything granting +1 to all skills
gd-explorer items --skill "all skills"

# items that grant the Ring of Steel skill
gd-explorer items --skill "ring of steel"

# any item with a +skill bonus at all
gd-explorer items --skill ""
```

#### `items` options

| Option | Description |
|--------|-------------|
| `--type TYPE` | Item slot/type, e.g. `helm`, `ring`, `amulet`, `sword`, `chest` (common synonyms like `helm`→head are understood) |
| `--resist RES` | Require a resistance: `fire`, `cold`, `lightning`, `poison`, `aether`, `chaos`, `vitality`, `pierce`, `bleed` (repeatable) |
| `--damage DMG` | Require an offensive damage type, same vocabulary plus `physical`/`elemental` (repeatable) |
| `--skill SKILL` | Require a `+`skill bonus whose text contains `SKILL` (case-insensitive substring, e.g. `"all skills"`, `"ring of steel"`); use `""` to match any item with a skill bonus (repeatable) |
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
