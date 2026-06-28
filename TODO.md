* [DONE] Add a selector of items that triggers the "upgrades" path and shows
  alternate options for put in the slot (noting that components/augments should
  be maintained). Include these on shopping list, noting the location is a
  character+stash/inventory/equipped rather than a faction.

  Implemented:
  - Backend `GET /api/characters/:name/items?slot=N` → `rankItems` (View.hs):
    scores every owned item of the slot's type via the `upgrades` scoring path
    (`mkScoreBase`/`scoreItems` in Report/Stats); candidate inherits the slot's
    component/augment (`inheritGear`); returns improvements best-first with each
    item's location.
  - `GearOverride.goItem` swaps a slot's base item (keeping component/augment);
    server parses `item.<i>` query params alongside `comp.<i>`/`aug.<i>`.
  - Shopping list now includes `kind:"item"` entries whose `source` is the owned
    location (e.g. "Adam (stash)"), grouped separately from faction augments.
  - Frontend `ItemPicker` (components/ItemPicker.tsx) on every gear card: fetches
    the ranked alternates on open (name + location + score/dps delta); picking one
    swaps the base item; "Keep equipped" reverts.
