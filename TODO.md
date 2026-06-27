* Add a selector of items that triggers the "upgrades" path and shows alternate options for put in the slot (noting that componnets/augments should be maintained). Include these on shopping list, noting the location is a character+stash/inventory/equipped rather than a faction.
* Store selected items/components/aguments in local storage so they are maintained over reload. Add a "reset" button next to each and a "reset all".
* Cache upgrade scorings in memory on server
* Difficulty selector at top of character page that changes resistance penalties.
* Include "best attack" in the main stats card, then make that card the "sticky" one. Remove the more compact sticky summary.
* In the character summary card include a table for each damage type. Columns are type/instant flat/instant %/DoT flat/DoT %. DoT flat is a tricky calculation, don't use any expected value, just do total / duration summed for each source.
* Current process to run server in bin/serve recompiles everything (probably because stack run changes flags?) Is there an alternate approach that reuses compilation from development?
* Show the ranking of component/augment/item in the list (on RHS)
* Bladed plating is being ranked too high in recommendations.
* In component/augement description, not obvious which stat is resistance and which is damage.
* "^kMark of Dreeg" what's that "^k" doing at the start? (Component on weapon of Shield character)
* Group shopping list by faction or character (for items), and include reminder of which slot it goes on.
