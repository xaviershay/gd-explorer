# gd-explorer — Implementation Plan

A read-only Haskell library + CLI for exploring Grim Dawn save data. Builds the
data-format readers from the ground up, validated incrementally with tests, then
layers the two target use cases on top.

Reference implementation: `../gd-edit` (Clojure). We port the *reading* half of
its data model; we never write save files. File paths to the relevant Clojure
sources are cited per phase so the exact byte layouts can be re-checked.

## Target use cases (from SPEC.md)
1. **Set completion** — across the shared (transfer) stash and all characters,
   show which set items I own and which I'm missing.
2. **Filterable inventory** — across the shared stash and all characters, list
   items filterable by resistance, damage type, item type, etc.

## Decisions (confirmed with user)
- **Data location:** everything under `data/gd`, laid out as:
  ```
  data/gd/
    game/
      database/database.arz           # base game item/skill/set DB
      resources/Text_EN.arc           # base English localization
      gdx1/database/GDX1.arz          # Ashes of Malmouth
      gdx1/resources/Text_EN.arc
      gdx2/database/GDX2.arz          # Forgotten Gods
      gdx2/resources/Text_EN.arc
      gdx3/database/GDX3.arz          # Fangs of Asterkarn
      gdx3/resources/Text_EN.arc
    save/
      transfer.gst                    # shared/transfer stash (.gsh if hardcore)
      main/<CharacterName>/player.gdc # one folder per character
  ```
  DLC databases/text layer on top of the base (later DLCs override by recordname;
  text tables merge). Load **all** DLCs including GDX3.
- **Stat precision:** record-level. Filter on stats present in the base item +
  affix DB records (e.g. "has fire resistance", "is a helm", "physical damage"),
  using record-defined values/ranges. Do **not** reconstruct exact per-item rolls
  from the random seed.
- **Interface:** one-shot subcommands (non-interactive), e.g.
  `gd-explorer sets`, `gd-explorer items --resist fire --type helm`.
- **Read-only:** the library only parses; no save writing.

## Toolchain
- Stack, snapshot **lts-24.45** (already pinned in `stack.yaml`).
- Test framework: **hspec**.
- New dependencies to add in `package.yaml` (library): `bytestring`, `containers`,
  `unordered-containers`, `text`, `vector`, `directory`, `filepath`, `mtl`.
  Executable also: `optparse-applicative`. Tests: `hspec`.
- **LZ4 decompression** (needed for ARZ + ARC): raw LZ4 *block* format with a
  known decompressed size. Plan: thin FFI to system `liblz4`
  (`LZ4_decompress_safe(src, dst, srcSize, dstCapacity)`) via a small `cbits`
  binding, since we always know the output size. (Pure-Haskell `lz4` package is a
  fallback if FFI proves troublesome.) This is the main external risk — spike it
  first in Phase 1.

## Module layout (library under `src/`)
```
GrimDawn.Binary      -- pure little-endian reader over a strict ByteString
GrimDawn.Lz4         -- raw-block LZ4 decompression (FFI)
GrimDawn.Cipher      -- Grim Dawn save XOR stream cipher (enc table + state)
GrimDawn.Gdc         -- character (.gdc) reader: header + item blocks
GrimDawn.Stash       -- transfer stash (.gst) reader
GrimDawn.Arz         -- game database (.arz) reader -> recordname -> record
GrimDawn.Arc         -- localization/text (.arc) reader -> tag -> string
GrimDawn.Db          -- merged DB+text facade; record lookup, related records
GrimDawn.Item        -- item interpretation: name, set membership, filter attrs
GrimDawn.Aggregate   -- unify items across characters + stashes with locations
GrimDawn.Report.Sets -- set-completion query
GrimDawn.Report.Items-- filterable-item query
GrimDawn.Cli         -- optparse-applicative wiring
```
`app/Main.hs` becomes a thin shim over `GrimDawn.Cli`.

## Testing strategy
- **Deterministic fixtures, checked in:** copy `../gd-edit/test-resources/save-files/Odie.gdc`
  into `test/fixtures/`. It is a real character save and gives us a stable target
  for the `.gdc` reader (name, class, level, item counts).
- **Real-data tests:** ARZ/ARC/stash readers and the end-to-end reports validate
  against `data/gd`. Guard these so they **skip gracefully** when `data/gd` is
  absent (so the suite is green in CI / on a fresh clone). Use a helper that
  checks for the file and `pendingWith` a message if missing.
- **Unit fixtures:** hand-built `ByteString`s for `GrimDawn.Binary` and
  `GrimDawn.Cipher` primitives; small synthetic records for `GrimDawn.Item`
  filter logic.

---

# Phases

Each phase is independently buildable and testable. Do them in order; do not start
a phase until the previous one's tests pass.

## Phase 0 — Project scaffolding
- Update `package.yaml`: add the dependencies above; add `default-extensions`
  as needed (e.g. `OverloadedStrings`, `LambdaCase`). Keep `-Wall`.
- Replace template `src/Lib.hs` with the first real module (Phase 1).
- Replace `test/Spec.hs` with an hspec discover entrypoint
  (`{-# OPTIONS_GHC -F -pgmF hspec-discover #-}`) and add a `test/` tree.
- Add `cbits/lz4_shim.c` placeholder + `extra-libraries: lz4` (or use bundled).
- **Done when:** `stack build` and `stack test` run (empty suite passes).

## Phase 1 — Binary reader + LZ4 spike
Port the read primitives from `../gd-edit/src/gd_edit/structure.clj`
(`bytebuffer-reader-fns`, `read-spec :string`) — read-only, little-endian.
- `GrimDawn.Binary`: a `Get`-style state monad over `(ByteString, Int offset)`:
  `int8/16/32/64`, `word32`, `float32`, `bytes n`, `skip n`,
  `asciiString` (int32 length prefix), `utf16leString`, fixed-length variants,
  `lengthPrefixedArray`. Keep it pure and total (return `Either` on overrun).
- `GrimDawn.Lz4`: `decompress :: Int -> ByteString -> Either String ByteString`
  (decompressed size known). FFI to `LZ4_decompress_safe`.
- **Tests:** round-trip each primitive against hand-built bytes (incl. UTF-16LE
  and negative ints). For LZ4, compress a known blob with the `lz4` CLI at build
  time *or* commit a tiny `(compressed, expected)` fixture and assert decompress.
- **Done when:** primitive tests pass and LZ4 decompresses a known block.

## Phase 2 — Save cipher + character (.gdc) reader
Reference: `../gd-edit/src/gd_edit/io/gdc.clj`. This is the trickiest phase.

### Cipher (see Appendix A for the exact algorithm)
`GrimDawn.Cipher` holds `encState :: Word32` and the 256-entry `encTable`.
Provide decrypting reads (`decInt`, `decByte`, `decBool`, `decFloat`,
`decBytes n`, `decString`) that thread/advance `encState`, plus
`advanceOver :: ByteString -> Cipher -> Cipher` (feed raw ciphertext bytes through
the table without producing a value — used to skip blocks).

### Block framing — key simplification
A `.gdc` is a preamble + header read *through* the cipher, then a sequence of
length-delimited blocks. **We only need blocks 3 (inventory) and 4 (personal
stash).** Every other block can be skipped: read its id and length, then advance
the cipher over the raw body bytes and verify the trailing checksum. This avoids
modelling the ~15 other block types entirely.

Per block: `id` (decInt, advances state) · `length` (raw u32 XOR state, does
**not** advance) · `body` (length bytes; advances) · `checksum` (raw u32, does
**not** advance; must equal current state).

### What to parse
- `FilePreamble` (magic == "GDCX", version), `Header`
  (character-name UTF-16LE, male bool, player-class-name, level, hardcore-mode,
  expansion flag), then header-checksum, data-version (∈ {6,7,8}), 16-byte
  mystery field.
- **Block 3** (`read-block3`): inventory sacks (each = array of `Item` + X/Y),
  12 equipment slots, two alt weapon sets. Each `Item` =
  basename, prefix-name, suffix-name, modifier-name, transmute-name, seed,
  relic-name, relic-bonus, relic-seed, augment-name, unknown, augment-seed,
  relic-completion-level, stack-count (+ slot-specific X/Y or `attached`).
- **Block 4** (`read-block4`): per-character personal stash tabs, each a grid of
  `StashItem` (= `Item` + X/Y).
- Produce a `Character { name, className, level, hardcore, equipped, inventory,
  personalStash }` where every item carries its source slot.
- **Done when:** parsing `test/fixtures/Odie.gdc` yields the expected name/class/
  level and a stable, asserted item count (cross-check against gd-edit if needed).

## Phase 3 — Transfer stash (.gst) reader
Reference: `../gd-edit/src/gd_edit/io/stash.clj`. Same cipher as `.gdc`.
- Layout: seed int, magic (decInt) == 2, then a single **Block 18**:
  version, an `int32-` (read with current state but **no** state advance — see
  `read-int-no-update`), mod string, expansion-status byte, then an array of
  inventory sacks; each sack = width, height, array of `TransferStashItem`
  (= `Item` + **float** X/Y).
- `GrimDawn.Stash` returns `[StashTab]` of items (each item tagged with its tab).
- **Tests:** validate against `data/gd/save/transfer.gst` (skip if absent):
  assert it parses, tab count > 0, and item basenames look like `records/items/…`.
  Capture a golden item count.
- **Done when:** real transfer stash parses and item count is asserted.

## Phase 4 — Game database (.arz) reader
Reference: `../gd-edit/src/gd_edit/io/arz.clj`.
- Header: u16 unknown, u16 version, record-table-start/size/entries,
  string-table-start/size.
- String table at `string-table-start`: u32 count, then `[u32 len, bytes]`×count.
- Record headers at `record-table-start`: per entry — filename (u32 →
  string-table index), type (ascii string), offset, compressed-size,
  decompressed-size, 2× u32 unknown.
- Record body: at `offset + 24`, LZ4 block → `decompressed-size` bytes. Parse
  fields until exhausted: u16 type, u16 count, u32 fieldname (string-table idx),
  then `count` values — type 1 = float, type 2 = string (string-table idx;
  resolve via localization table if it starts with "tag"), else int32.
- Result: `Map recordname Record`, `Record = Map FieldName Value`
  (`Value = VInt Int | VFloat Float | VString Text | VList [...]`).
- **Performance:** the full DB is large. Parse record *headers* eagerly but
  consider only fully decoding records whose recordname starts with
  `records/items/` (covers items, affixes, and set definitions) to cut time/memory.
  Use strict `ByteString` and `HashMap`. Decompress records in parallel if needed
  (mirrors gd-edit's `pmap`).
- Layer base + GDX1 + GDX2 + GDX3, later DLC winning on key collision.
- **Tests** (skip if `data/gd` absent): assert the header magic/version, that the
  string table is non-empty, and that a couple of known item recordnames resolve
  with expected fields (pick stable base-game records, e.g. a known component).
- **Done when:** merged DB loads and spot-check records resolve.

## Phase 5 — Localization (.arc) reader
Reference: `../gd-edit/src/gd_edit/io/arc.clj`.
- Header (magic `0x435241` "ARC", version 3), record headers (incl. multi-part
  file parts), LZ4-decompress each record (possibly several parts concatenated),
  each record is text: `key=value` lines → merge into `Map Text Text`.
- Layer base + DLC text tables (later wins). Wire this into Phase 4 so ARZ "tag…"
  strings resolve to display names at DB-build time (as gd-edit does).
- **Tests** (skip if absent): assert a known tag (e.g. a common resistance tag)
  resolves to expected English text.
- **Done when:** text table loads and known tags resolve; DB item names resolve.

## Phase 6 — Item interpretation
Reference: `../gd-edit/src/gd_edit/db_utils.clj` (esp. `item-name`,
`related-db-records`, `item-base-record-get-name`) and field names in
`../gd-edit/src/gd_edit/item_summary.clj`.
- `relatedRecords item db` — every `records/…` value referenced by the item's
  basename/prefix/suffix/relic/augment names.
- `itemName` — combine prefix + quality + base + suffix display names; for set
  items (any related record has `itemSetName`) use quality + base only.
- `isSetItem` and `setRecordName` for an item.
- `filterAttributes item` — derive the record-level attributes the `items`
  command filters on:
  - **item type / class** from base record `Class` / `itemClassification` /
    slot (helm, chest, ring, one-handed, etc.),
  - **resistances** (fire/cold/lightning/poison/aether/chaos/vitality/pierce/
    bleed) from base+affix resist fields,
  - **damage types** from offensive damage fields,
  - **level requirement**.
  Enumerate the exact GD field names from the DB (confirm against real records);
  keep a mapping table `field -> attribute`.
- **Tests:** build small synthetic `Record`s and assert `itemName`, set detection,
  and `filterAttributes` outputs. Add one real-data assertion on a known item.
- **Done when:** naming + attribute extraction verified on synthetic and one real
  item.

## Phase 7 — Aggregation across sources
- `GrimDawn.Aggregate`: load all `save/main/*/player.gdc` + `save/transfer.gst`,
  produce `[(OwnedItem, Location)]` where `Location` ∈ equipped(char),
  inventory(char), personalStash(char), sharedStash. Reuse one loaded DB.
- **Tests** (skip if absent): assert total item count across sources is stable and
  that locations are populated for each source type.
- **Done when:** a single call returns every owned item with provenance.

## Phase 8 — Set completion report
- Discover set definitions in the DB. **First task: confirm the set-record schema
  against real data** — the member item records carry `itemSetName` pointing to a
  set record; determine the set record's `Class` and its member-list field
  (and the set display name). Cross-check with `db_utils.clj` and a real set you
  can verify in-game.
- For each set: list member item records; mark each owned (match item basename to
  a member recordname across all aggregated sources) vs missing. Summarize
  per-set completion (e.g. `Krieg's Mortpyre  3/5  missing: Helm, Boots`).
- `GrimDawn.Report.Sets`.
- **Tests:** spot-check one set you can verify; unit-test the owned/missing diff
  with synthetic data.
- **Done when:** `sets` report matches reality for at least one verified set.

## Phase 9 — Filterable items report
- `GrimDawn.Report.Items`: predicate combinators over `filterAttributes`
  (`--type`, `--resist`, `--damage`, `--set`, `--char`, `--min-level`, etc.).
  Render a table (name, type, key stats, location, count).
- **Tests:** unit-test each predicate over synthetic items; integration smoke test
  over real data (skip if absent).
- **Done when:** filters compose correctly and an end-to-end query returns
  expected rows on real data.

## Phase 10 — CLI wiring
- `GrimDawn.Cli` (optparse-applicative): global `--data-dir` (default `data/gd`);
  subcommands `sets` and `items` (with the filter flags). Table output to stdout.
- `app/Main.hs` calls into it.
- **Tests:** parse a few argv vectors to the expected command records.
- **Done when:** `stack run -- sets` and `stack run -- items --resist fire`
  work against `data/gd`.

---

# Risks / things to verify early
1. **LZ4 binding** (Phase 1) — confirm raw-block decompress against real ARZ data
   ASAP; everything downstream depends on it.
2. **Cipher fidelity** (Phase 2) — the XOR stream + block framing must be exact;
   the `Odie.gdc` fixture is the guard. The block-skip optimization assumes every
   field advances state purely as a function of its ciphertext bytes (true — see
   Appendix A); validate by checking block checksums.
3. **Set-record schema** (Phase 8) — exact `Class`/member-field names need
   confirmation against real data.
4. **DB performance** (Phase 4) — full DB is big; the `records/items/` filter and
   strict structures should keep it manageable; revisit if load time is poor.
5. **`.gst` fixture** — no checked-in sample; relies on the user's real
   `transfer.gst`. Consider saving a tiny redacted golden once available.

---

# Appendix A — Save file XOR stream cipher (exact)
Used by both `.gdc` and `.gst`. From `gd-edit/src/gd_edit/io/gdc.clj`.

- **Seed:** read first 4 bytes as u32 LE; `seed = raw XOR 0x55555555`.
- **Table:** 256 entries. `v = seed`; for `i` in 0..255:
  `v = ((v << 31) | (v >> 1)) * 39916801  (mod 2^32)`; `table[i] = v`.
  (i.e. `table[0]` derives from `seed`, each subsequent from the previous.)
- **State:** `encState` starts at `seed`.
- **Decrypt a u32** (LE in file): `plain = (cipher XOR encState) & 0xffffffff`,
  then advance: for each of the 4 little-endian bytes `b` of the *cipher* value,
  `encState ^= table[b]`.
- **Decrypt a byte:** `plain = (cipher XOR encState) & 0xff`; then
  `encState ^= table[cipher]`.
- **Decrypt a float:** decrypt the 4 bytes as a u32 (bit pattern), advancing state
  as for u32, then reinterpret bits as IEEE-754 float.
- **Decrypt a string:** read length (a decrypted u32 unless static), then read N
  bytes (×2 for UTF-16LE); each byte `c`: `plain = (c XOR encState) & 0xff`,
  `encState ^= table[c]` (state advances per ciphertext byte, in file order).
- **Skipping bytes:** because every field advances state purely from its ciphertext
  bytes in file order, skipping a region == feeding its raw bytes through the table
  (`encState ^= table[b]` per byte) without decoding.
- **Block framing:** `id` = decrypted u32 (advances). `length` = raw u32 XOR
  current `encState` (consumed, **no** advance). `body` = `length` bytes (advances
  per byte). `checksum` = raw u32 (consumed, **no** advance) and must equal
  `encState`. (`.gst` Block 18 additionally has an `int32-` field decrypted with
  current state but with **no** advance — `read-int-no-update`.)
- File-level after header: a raw u32 header-checksum (== encState), then
  `data-version` (decrypted u32, ∈ {6,7,8}), then a 16-byte mystery field
  (decrypted bytes), then the block sequence to EOF.
