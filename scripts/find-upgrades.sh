#!/usr/bin/env bash
#
# find-upgrades.sh — thin wrapper around `gd-explorer upgrades`, kept for the
# positional "CHARACTER SLOT" ergonomics. The search now runs entirely in the
# binary (the database loads once), so this just forwards to it.
#
# Usage:
#   scripts/find-upgrades.sh [CHARACTER] [SLOT] [options...]
#     defaults: Shield boots
#   options are passed straight through, e.g.
#     --difficulty normal|elite|ultimate   (default: ultimate)
#     --target N                            resistance goal % (default: 80)
#     --max-level N                         only items requiring level <= N
#     --buffs permanent,temporary,proc      fold in skill buffs (default: none)
#     --weight CAT=FACTOR                   resist|oa|da|damage (repeatable)
#
# Equivalent direct form:
#   gd-explorer upgrades CHARACTER --slot SLOT [options...]

set -euo pipefail

CHAR=Shield
SLOT=boots
# peel up to two leading positional args (anything not starting with '-')
if [ "$#" -ge 1 ] && [ "${1:0:1}" != "-" ]; then CHAR=$1; shift; fi
if [ "$#" -ge 1 ] && [ "${1:0:1}" != "-" ]; then SLOT=$1; shift; fi

# Prefer the built binary directly; fall back to `stack exec`.
BIN="$(stack path --local-install-root 2>/dev/null)/bin/gd-explorer"
if [ -x "$BIN" ]; then
  exec "$BIN" upgrades "$CHAR" --slot "$SLOT" "$@"
else
  exec stack exec gd-explorer -- upgrades "$CHAR" --slot "$SLOT" "$@"
fi
