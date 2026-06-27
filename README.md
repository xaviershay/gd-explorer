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
    formulas.gst                 # learned crafting blueprints (optional)
    main/<CharacterName>/player.gdc
```

If `formulas.gst` is present, the items your learned blueprints can craft are
included in the `sets` and `items` reports, marked **craftable (blueprint)** — so
a set piece you can craft counts toward completion. It's optional; without it
those reports just show what you physically own.

DLC tiers are optional — whatever is present is loaded and merged, with later
DLCs overriding earlier ones.

### Staging the data (incl. from another machine)

Grim Dawn is usually installed on a different machine. Two helper scripts collect
just the ~100 MB subset above and can push it here over SSH (run them on the
machine that has the game; they only need `bash` + `rsync`):

- **`scripts/sync-data.sh <game-dir> <save-dir>`** — explicit paths, any OS. Add
  `--to [user@]host:/path/to/gd-explorer/data/gd-data` to rsync it to this repo
  over SSH (otherwise it writes locally to `data/gd-data`; `--dest DIR` overrides;
  `--mirror` deletes stale remote files):

  ```sh
  # on the Grim Dawn machine (after scp'ing the script over):
  ./sync-data.sh --to me@devbox:/home/me/code/gd-explorer/data/gd-data \
      "/path/to/Grim Dawn" "/path/to/.../My Games/Grim Dawn/save"
  ```

- **`scripts/fetch-gd-data.sh [user@host:/path/to/.../data/gd-data]`** — for a
  Windows install under WSL: auto-detects the game install and saves (Documents
  and Steam Cloud), then stages and rsyncs to the destination. With no
  destination it stages locally and prints the path to copy yourself.

Either way the result is the `data/gd-data` layout shown above. You can also pull
from here instead of pushing, e.g.
`rsync -avz me@gamebox:/tmp/gd-bundle/ data/gd-data/`.

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
indented detail lines for resistances (with their percentages), **damage
bonuses** (`+` flat and `%` modifiers), **stat bonuses**, and **skill bonuses**
(only the lines that apply are shown).

Damage types follow Grim Dawn's immediate/damage-over-time distinction: the bare
element field is the immediate hit (Fire, Cold, Lightning, **Acid**, Physical,
Vitality, …) while the "Slow" variant is the DoT, shown over its duration
(**Burn**, **Frostburn**, **Electrocute**, **Poison**, **Internal Trauma**,
**Vitality Decay**) — e.g. `+30 Burn over 3s`. The stat-bonus labels (and this
naming) are ported from gd-edit's `effect-string-map` / `effect-types`, so
coverage matches gd-edit: attributes, health/energy and regen, OA/DA, armor and
absorption, speeds, experience gain, leech, retaliation, crit/total damage,
block, control/maximum resistances, and more.

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
    resists: 18% Chaos, 22% Cold, 22% Fire, 22% Lightning
    damage : 44% Physical
    bonuses: +222 Armor, +180 Health, +30 Offensive Ability
    skills : +2 Judgment, +2 Blade Arc
Champion of the Light [Epic] axe2h lvl 72 — Adam (stash) x1
    damage : +260-300 Lightning, 120% Lightning
    skills : +4 Oak Skin, +4 Counter Strike
```

Damage, stat, and skill bonuses are aggregated from the item's base and affix
records. Per the record-level approach, ranges shown reflect the database
values, not the exact per-item roll.

### `character` — a character's gear, skills, and devotions

```sh
gd-explorer character             # list character names
gd-explorer character xavier      # full report for one character
```

Prints the character's level and class, every equipped item (same block format
as `items`), the **active set bonuses** (aggregated per set, with the equipped
piece count — not repeated on each item), their skills grouped by mastery (with
the mastery rank), and their devotions grouped by constellation (star counts and
the celestial power each grants). Colouring follows the same terminal-only rule
as `items`.

```
xavier  —  Level 41  Elementalist

Equipped:
  Gunslinger's Jacket [Epic] chest lvl 20
    resists: 18% Vitality
    damage : 40% Fire, 40% Vitality
    bonuses: +130 Armor, +26 Cunning, +5% Attack Speed
    skills : +3 Flame Touched, Grants Gunslinger

Set Bonuses:
  Perdition  (3/5)
    damage : 50% Poison
    bonuses: Increases Armor by 10%, +50% Poison Retaliation

Skills:
  Demolitionist (40)
    +12 Flame Touched
    +12 Blackwater Cocktail
  Shaman (26)
    +10 Summon Briarthorn

Devotions (19 points):
  Imp  (5 stars)  grants Aetherfire
  Fiend  (5 stars)  grants Flame Torrent
```

The set bonus shown reflects the tier active at the current piece count; set
bonus fields are arrays indexed by pieces-equipped, resolved against the same
renderer used for item bonuses.

#### Stat totals

The character view always ends with a **Stats** summary that aggregates totals
across equipped gear, set bonuses, devotion passives, and mastery ranks:

- **Resistances** with the difficulty penalty applied and the per-type cap
  (default 80%, raised by any `+% maximum resistance`), flagging types left
  negative as `LOW`. Choose the penalty tier with
  `--difficulty normal|elite|ultimate` (0 / -25 / -50; default normal).
- **Attributes** (Physique / Cunning / Spirit) as **absolute** totals: the
  character's allocated base (from the save) plus mastery ranks, gear, devotions
  and buffs, with the percent modifier applied.
- **Defenses & Offense** (Offensive/Defensive Ability, Armor, Health, Energy):
  the contribution from gear/mastery/buffs. These are *not* absolute — the innate
  per-level OA/DA base lives in creature records that aren't in the extracted
  database, so the per-level/attribute-derived base is not included.
- **Weapon damage** per equipped weapon, and the total **damage bonuses** from
  gear.

```sh
gd-explorer character Shield --difficulty ultimate
```

Skill buffs are opt-in via `--buffs` (a comma list of `permanent`, `temporary`,
`proc`, or `all`/`none`; default `none`), mirroring Grim Tools' toggles. Buff
values are resolved at the **effective** skill rank — the invested rank plus any
`+all skills`, `+mastery` and `+specific skill` bonuses from gear and devotions —
and skill **modifier** nodes (e.g. the resistances a node adds to an aura) are
folded in under their parent skill's category. Attack skills are not folded in
(their bonuses are conditional on using the ability).

```sh
gd-explorer character Shield --buffs permanent,temporary
```

#### `--overlay` — compare candidate gear

`--overlay NAME` (repeatable) swaps an owned item (matched by name) into its slot
on the base character and prints the stat **diff** (resistances and key totals as
`base -> new (delta)`), so you can see the impact of a gear change. The swapped-in
item **inherits the replaced item's component and augment** (unless it has its
own), so the comparison assumes you move your sockets over rather than losing
them. Components and augments are always counted toward an item's resists/bonuses.

```sh
gd-explorer character Shield --overlay "Faceguard of Perdition" --difficulty ultimate
```

```
Overlaying: Faceguard of Perdition

Overlay vs equipped  [Ultimate]

Resistances:
  Poison & Acid    -23% ->    1%  (+24)
  Chaos             33% ->   21%  (-12)

Defenses & Offense:
  Armor                 +1218 ->   +1454  (+236)
  Health                +1112 ->    +912  (-200)
  Damage                +1180 ->   +1252  (+72)
```

### `upgrades` — search a slot for better gear

Scores every owned item in a slot as an overlay and ranks the net-positive ones.
The whole search runs in one process (the database loads once):

```sh
gd-explorer upgrades Shield --slot boots --difficulty ultimate
```

Up to the **three** best options are shown, each titled with the item's name and
**where it lives** (equipped/inventory/stash), its resistance changes stacked
one-per-line (for easy comparison), and a single OA/DA/`~DPS` summary. The `~DPS`
figure folds the whole damage picture into one number — the change to your
**highest-DPS attack with every proc included** — so it reads as "roughly this
much more/less damage":

```
Top 3 boots for Shield (ultimate; weights resist=2 oa=30 da=80 damage=1):

  +8041  lvl 50  Golemborn Greaves  [shared stash]
        Poison & Acid     -13% ->     2%  (+15)
        Pierce            -22% ->    20%  (+42)
        Bleeding          -12% ->   -24%  (-12)
        Physical          -50% ->   -46%  (+4)
        [DA +24, ~DPS +312]
```

Each candidate is scored as a weighted sum of:

- **resist** — non-linear: each resistance is penalised by the *square* of its
  shortfall below `--target` (default 80), so a point of resist is worth more the
  lower the resistance is. This favours raising your weakest resistances and
  spreading losses (e.g. `-1` on eight beats `-8` on one).
- **oa / da** — change in Offensive / Defensive Ability.
- **damage** — change in the `~DPS` estimate above.

The defaults (`resist=2 oa=30 da=80 damage=1`) weight survivability —
resistances and Defensive Ability — well above raw damage, so a piece that plugs
a resist or DA hole beats one that only adds offence. Tune the mix with `--weight
CAT=FACTOR` (repeatable; `CAT` ∈ `resist oa da damage`).

The two ring slots are searched independently: `--slot ring1` compares candidates
against your first equipped ring, `--slot ring2` against the second (an empty ring
slot is treated as a pure addition). Other options: `--target`, `--max-level N`
(only items requiring ≤ N), and `--buffs` (as for `character`).
Resist types are coloured on a terminal, and each row shows the item's level
requirement. `scripts/find-upgrades.sh [CHAR] [SLOT] [opts]` is a thin wrapper
with positional character/slot.

```sh
# value damage twice as much, ignore OA/DA, only usable boots:
gd-explorer upgrades Shield --slot boots --weight damage=2 --weight oa=0 --weight da=0 --max-level 45
```

### `dps` — estimate attack-skill damage

Estimates per-hit and DPS, split into **attacks you pick between** and **procs
that fire automatically while you attack** (additive), with an estimated total:

```sh
gd-explorer dps Adam
```

```
Attacks (pick one):
  Fire Strike (21)              per-hit ~  21591  ~  33465 dps  (~1.6/s attacks (assumed base))
        Fire ~10660; Acid ~713; Chaos ~279; Burn (dot) ~9725; Poison (dot) ~214
  Bursting Round (13)           per-hit ~  13743  ~  21302 dps  (~1.6/s attacks (assumed base))
        Fire ~7735; Acid ~577; Burn (dot) ~5265; Poison (dot) ~166
  Weapon Attack                 per-hit ~   8019  ~  12429 dps  (~1.6/s attacks (assumed base))
        ...
Procs (auto, while attacking):
  Meteor                        per-hit ~  26383  ~   4608 dps  (20% on attack, 2.5s cd)
        Fire ~5921; Acid ~480; Burn (dot) ~19982
  Meteor Shower                 per-hit ~   3563  ~    630 dps  (30% on attack, 3.5s cd)
        Fire ~1011; Acid ~54; Burn (dot) ~2498
  Vindictive Flame              per-hit ~   1279  ~    596 dps  (100% on hit, 1.5s cd)
        Fire ~1233; Acid ~46
  ...
Estimated total: best attack ~33465 + procs ~8332 = ~41798 dps
```

Per type, per-hit = `(weapon-flat × weaponDamagePct + skill-flat) × (1 + %damage)`,
with the skill resolved at its effective rank (including `+skills`) and the
weapon-flat being your total flat damage (weapon base + gear). **Retaliation
damage added to attack** is included too: a skill's `% retaliation added to
attack` (global, or from a modifier like **Reprisal** on Avenging Shield) adds
that fraction of your retaliation as weapon damage — which is why a high
weapon-damage retaliation skill spikes. **Damage-type conversions are applied** —
global ones from gear/devotions and skill-specific ones from a skill's
transmuters/modifiers (e.g. Aegis of Thorns converting Avenging Shield's Fire to
Acid), with converted damage picking up the destination type's `%` modifiers.
DPS is `per-hit ÷ cooldown` for cooldown
skills, or `per-hit × attacks/sec` for spam attacks using an **assumed** base
attack speed (× your `+%` attack speed), since the real per-weapon base speed
isn't in the extracted database. A primary attack also folds in its invested
**transmuters/modifiers/secondaries** — their added flat damage (e.g. Volcanic
Stride's hit on Vire's Might), conversions, retaliation-added, and cooldown
changes (e.g. Tectonic Shift's −cooldown). **Damage-over-time** is included as a
`(dot)` term: per-application total (per-second × duration, with duration/`%`
modifiers) × the attack rate — valid because GD DoTs stack. **Chance-based
cooldown resets** (e.g. Reprisal) count as expected value (`chance × reduction`).
Conversions apply to the DoT too (e.g. Fire→Acid turns Burn into the Poison DoT).
A bare **Weapon Attack** row (100% weapon damage, no skill) is always included as
a baseline.

**Procs** are gathered from gear-granted skills (`itemSkillName` + a
`cast_@…` controller), devotion-bound skills (`templateAutoCast`), and learned
on-hit skills (e.g. Vindictive Flame). Each proc's expected DPS is
`per-hit ÷ (cooldown + 1 / (chance × attacks-per-second))` — the cooldown plus
the average wait for the next successful trigger. Proc damage is flat (not
weapon-scaled) but still gets your conversions and `%` modifiers. Only
attack-driven triggers are modelled (on attack / hit / melee); on-crit, on-block,
on-kill, and low-health procs are skipped, and persistent multi-hit ground
effects (Meteor Shower, Fissure) are counted as a single hit (an undercount).

This is a **rough, relative** estimate: no crit, enemy resistances, or the
"Elemental"/multi-type conversion forms — good for comparing ranks/gear, not a
true DPS. `--buffs` works as for `character`.

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

### `serve` — local web UI

A browser front-end over the same data. The server loads the game database once
(~3.5 s, ~1.5 GB) and keeps it resident; the small save data is re-read on every
request, so the UI always reflects your latest play session without a restart.

```sh
# build the frontend once (outputs frontend/dist)
npm --prefix frontend install
npm --prefix frontend run build

# run the server (serves the API + the built frontend)
gd-explorer serve            # http://localhost:8080
gd-explorer serve --port 9000 --data-dir data/gd-data --static frontend/dist
```

Three starting views:

- **Sets** — a compact map of every item set, each cell coloured by completion;
  click a set to see which pieces you own (and where) versus what's missing.
- **Characters** — a summary card per character (level, class, hardcore, equipped
  set-piece count).
- **Character detail** — the gear a character has equipped, coloured by rarity
  with resist / damage / skill bonuses.

JSON endpoints (handy on their own): `GET /api/sets`, `GET /api/characters`,
`GET /api/characters/:name`.

**Frontend development.** The UI is a React + TypeScript + Vite app under
`frontend/`. For live reload, run the Vite dev server (it proxies `/api` to the
Haskell server on `:8080`):

```sh
gd-explorer serve              # terminal 1 — API on :8080
npm --prefix frontend run dev  # terminal 2 — UI on :5173 (proxies to :8080)
```

## How it works

Items are matched at the **record level**: filters test the stats defined on the
base item and affix records in the database (e.g. "has fire resistance", "is a
helm"), not the exact per-item rolled values. Tag strings resolve to English
display names via the merged localization tables.

See `PLAN.md` for the module layout and the save-file format details.
