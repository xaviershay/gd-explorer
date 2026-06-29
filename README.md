# gd-explorer

Slopped up library for exploring 
[Grim Dawn](https://www.grimdawn.com/)
save data. Very messy. It parses the game database (`.arz`), localization (`.arc`), your
characters (`.gdc`), and the shared transfer stash (`.gst`) to answer 
questions across all your characters and the shared stash:

1. **Set completion** — which set items you own and which you're missing.
2. **Filterable inventory** — list items filtered by resistance, damage type,
   item slot, set membership, character, and level.

Can also show character stats, estimate DPS, and search for better gear.

There is a CLI and a UI, both pretty nascent.

This README is probably out of date.

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

See `scripts/sync-data.sh` for collecting this data and putting in the right place.

  ```sh
  # on the Grim Dawn machine (after scp'ing the script over):
  ./sync-data.sh --to me@devbox:/home/me/code/gd-explorer/data/gd-data \
      "/path/to/Grim Dawn" "/path/to/.../My Games/Grim Dawn/save"
  ```

## Build & test

```sh
stack build
stack test
```

## Usage

```sh
bin/serve # Visit localhost:8080
```
