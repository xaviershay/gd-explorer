#!/usr/bin/env bash
#
# Collect the Grim Dawn files gd-explorer needs and (optionally) push them to
# another machine. Designed to run ON the machine that has Grim Dawn installed.
#
# Usage:
#   scripts/sync-data.sh [options] <game-dir> <save-dir>
#
#   <game-dir>  Grim Dawn install dir containing database/, resources/, and
#               (optionally) gdx1/ gdx2/ gdx3/ for the expansions.
#   <save-dir>  Grim Dawn save dir containing main/ (characters) and transfer.gst
#               (the shared stash). Often ".../my games/Grim Dawn/save".
#
# Options:
#   --to [USER@]HOST:PATH   After building, rsync the bundle to a remote machine
#                           over SSH. PATH is the remote gd-explorer data dir,
#                           e.g. me@devbox:/home/me/code/gd-explorer/data/gd-data
#   --dest DIR              Local output dir (default: data/gd-data). Ignored
#                           when --to is given (a temp staging dir is used).
#   --mirror                Pass --delete to the remote rsync (exact mirror;
#                           removes stale files under the remote PATH).
#
# Only the records gd-explorer reads are copied: the .arz databases, the English
# localization .arc files, each character's player.gdc, and transfer.gst. Missing
# expansion files are skipped (expansions are optional).
#
# This script is self-contained (just bash + rsync), so you can scp it to the
# Grim Dawn machine and run it there:
#   scp scripts/sync-data.sh me@gamebox:   # then, on gamebox:
#   ./sync-data.sh --to me@devbox:/home/me/code/gd-explorer/data/gd-data \
#       "<game-dir>" "<save-dir>"

set -euo pipefail

TO=""
DEST="${DEST:-data/gd-data}"
MIRROR=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to) TO=$2; shift 2 ;;
    --to=*) TO=${1#--to=}; shift ;;
    --dest) DEST=$2; shift 2 ;;
    --dest=*) DEST=${1#--dest=}; shift ;;
    --mirror) MIRROR=1; shift ;;
    -h | --help) sed -n '2,38p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [ "$#" -ne 2 ]; then
  sed -n '2,38p' "$0" >&2
  exit 1
fi

GAME_SRC=$1
SAVE_SRC=$2

[ -d "$GAME_SRC" ] || { echo "error: game-dir not found: $GAME_SRC" >&2; exit 1; }
[ -d "$SAVE_SRC" ] || { echo "error: save-dir not found: $SAVE_SRC" >&2; exit 1; }

# Build into a temp staging dir when pushing remotely, else into DEST directly.
if [ -n "$TO" ]; then
  BUILD=$(mktemp -d)
  trap 'rm -rf "$BUILD"' EXIT
else
  BUILD=$DEST
fi

# (database, localization) pairs gd-explorer loads, relative to <game-dir>,
# matching GrimDawn.Db's `tiers`. Base game is required; gdx* are optional.
GAME_FILES=(
  "database/database.arz"
  "resources/Text_EN.arc"
  "gdx1/database/GDX1.arz"
  "gdx1/resources/Text_EN.arc"
  "gdx2/database/GDX2.arz"
  "gdx2/resources/Text_EN.arc"
  "gdx3/database/GDX3.arz"
  "gdx3/resources/Text_EN.arc"
)

echo "Collecting game data -> $BUILD/game"
for rel in "${GAME_FILES[@]}"; do
  if [ -f "$GAME_SRC/$rel" ]; then
    mkdir -p "$BUILD/game/$(dirname "$rel")"
    rsync -a "$GAME_SRC/$rel" "$BUILD/game/$rel"
    echo "  + game/$rel"
  else
    echo "  - game/$rel (not found, skipping)"
  fi
done

echo "Collecting saves -> $BUILD/save"
mkdir -p "$BUILD/save"

if [ -f "$SAVE_SRC/transfer.gst" ]; then
  rsync -a "$SAVE_SRC/transfer.gst" "$BUILD/save/transfer.gst"
  echo "  + save/transfer.gst"
else
  echo "  - save/transfer.gst (not found, skipping)"
fi

if [ -d "$SAVE_SRC/main" ]; then
  rsync -a --prune-empty-dirs \
    --include='*/' --include='player.gdc' --exclude='*' \
    "$SAVE_SRC/main/" "$BUILD/save/main/"
  count=$(find "$BUILD/save/main" -name player.gdc 2>/dev/null | wc -l | tr -d ' ')
  echo "  + save/main/*/player.gdc ($count characters)"
else
  echo "  - save/main/ (not found, skipping)"
fi

if [ -n "$TO" ]; then
  host=${TO%%:*}
  path=${TO#*:}
  echo "Pushing to $TO ..."
  ssh "$host" "mkdir -p '$path'"
  opts=(-az)
  [ "$MIRROR" = 1 ] && opts+=(--delete)
  rsync "${opts[@]}" "$BUILD/" "$TO/"
  echo "Done -> $TO"
else
  echo "Done -> $BUILD"
fi
