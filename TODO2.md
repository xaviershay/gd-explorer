* [PARTIAL] Don't show physique/cunning/spirit in character summary card. Calculate actual OA, DA, Health, Energy.
  - DONE: dropped Physique/Cunning/Spirit from the summary card.
  - DONE: Health & Energy totals now computed (Stats.statSummary ssHealthTotal/
    ssEnergyTotal) and shown as a vitals row in the summary card (frontend
    SummaryPanel). Validated vs Shield: Health 16364 vs 15743 (+4%), Energy 2091
    vs 2058 (+1.6%). Formula anchors on stored charHealth/charEnergy (exact bio
    base) + health/energy from bonus attributes + flat/% modifiers.
  - DEFERRED (per user): OA/DA. Base OA/DA = 65 flat (malepc01), no per-level
    growth, masteries grant 0 direct OA/DA — yet Shield is ~1100 above the
    modelled OA/DA. Unresolved source (suspect an uncaptured permanent buff, e.g.
    "Eldritch Ruminations" which isn't in Shield's parsed buffs). Still shown as
    the +contribution figure in keyTotals.
  - DONE (research + parse): the bio block (Gdc block 2) DOES store base
    health/energy after phys/cun/spi — now parsed into charHealth/charEnergy
    (previously discarded). These are GD's pre-gear *base* totals.
  - Attribute formulas (web, Official GD Wiki / character-basics guide):
      Physique: +2.5 Health, +0.05 Health regen/s, +0.4 Defensive Ability /point
      Cunning:  +1.0 Health, +0.41% phys/pierce, +0.46% bleed/trauma, +0.4 OA /pt
      Spirit:   +1.0 Health, +0.47% magic, +0.5% magic-duration, +2 Energy /pt
      1 allocated attribute point = +8 to the attribute. Start = 50 each.
  - Verified against our saves: Energy == 150 + 2*Spirit (exact, 4/4 chars; no
    per-level term). Health ~= base + attr contribution but NOT a clean
    attribute-only formula (Odie's stored HP is below its pure-attr sum), i.e.
    the stored value bakes in mastery/per-level base, not just attributes.
  - OA/DA are NOT stored anywhere in the save (always recomputed). Community
    figure: +10 OA & +10 DA per level (needs confirming), + Cunning*0.4 (OA) /
    Physique*0.4 (DA), + gear/skill bonuses.
  - VALIDATED against Shield (lvl88, in-game HP 15743 / EN 2058 / OA 2070 / DA 2215):
    Use the app's *total* attributes (ssvAttributes already = bio + mastery +
    gear + devotion, correct), NOT the bio base. Masteries grant Health/Energy/
    attributes per bar rank but 0 direct OA/DA (OA/DA come from attributes).
      Health = (25 + Phys*2.5 + Cun*1 + Spi*1 + flatHealth) * (1 + %health)
               -> recon 16364 vs 15743 (+4%)
      Energy = (150 + Spi*2 + flatEnergy) * (1 + %energy)
               -> recon 2091 vs 2058 (+1.6%)
      OA = baseOA(lvl) + Cun*0.4 + flatOA, *(1+%OA)   [flat/% from keyTotals]
      DA = baseDA(lvl) + Phys*0.4 + flatDA, *(1+%DA)
    charHealth/charEnergy (bio base) are too low to display directly (exclude
    mastery/gear) -- compute from total attrs instead.
  - REMAINING: Health/Energy need NO leveltable (computable now, ~few % off,
    likely buff/rounding). OA/DA still need the innate per-level base (Shield
    implies ~1194 OA / ~1041 DA at lvl88; not equal, not a clean per-level const,
    not in the extract). DECISION: hardcode a per-level OA/DA base table, or sync
    the leveltable, or show OA/DA as "+contribution" only (current behaviour).
* [DONE] Rather than show # rank in suggested lists, show the underlying score.
* [DONE] On equipment show a consistent 5x2 grid for resistances, and grey out ones that don't apply.
* [DONE] Break top row of gear ... 7 rows, each with two items (head|amulet, ring|ring, shoulders|chest, hands|legs, waist|feet, weapon|weapon, relic|medal).
* [DONE] Include sections for skills and devotions on the character page. For devotions, group by constellation and include a small card with the summary of what it grants.
* [DONE] In character summary card, move resistances into a two-column (5 rows) icon table, consistent ordering, rows even when empty.
* [DONE] Come up with better formatting for the "best attack" (now a DPS headline: total + best-attack/procs breakdown).
* [DONE] faction labels. "Survivors"→Devil's Crossing, User7→The Black Legion.
  User2→Homestead now CONFIRMED (web): its augments Menhir's Blessing, Beast
  Tamer's Powder and Solar Radiance are all Homestead faction augments per
  grimtools/Official Wiki. (The earlier User2→Black Legion guess was wrong.)
  Name-matched ones (User4 Outcast, User8 Kymon's, User9 Coven, User10 Barrowholm,
  User11 Malmouth, User13 Bysmiel, User14 Dreeg, User15 Solael, User5 Death's
  Vigil, User0 Rovers) remain inferred from augment names — no authoritative
  enum->faction map exists in the game data.
